use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

const WORKER_SCRIPT: &str = include_str!("omni_asr_worker.py");
const REQUIREMENTS: &str = include_str!("omni_asr_requirements.txt");
const PYTORCH_CPU_INDEX: &str = "https://download.pytorch.org/whl/cpu";
const PYTORCH_CUDA_INDEX: &str = "https://download.pytorch.org/whl/cu124";
const PYTORCH_CUDA_BLACKWELL_INDEX: &str = "https://download.pytorch.org/whl/cu128";
const FAIRSEQ2_CPU_INDEX: &str = "https://fair.pkg.atmeta.com/fairseq2/whl/pt2.6.0/cpu";
const FAIRSEQ2_CUDA_INDEX: &str = "https://fair.pkg.atmeta.com/fairseq2/whl/pt2.6.0/cu124";
const FAIRSEQ2_CUDA_BLACKWELL_INDEX: &str =
    "https://fair.pkg.atmeta.com/fairseq2/whl/pt2.8.0/cu128";
const FAIRSEQ2_VERSION: &str = "0.6";
const TORCH_VERSION: &str = "2.6.0";
const TORCHAUDIO_VERSION: &str = "2.6.0";
const TORCH_BLACKWELL_VERSION: &str = "2.8.0";
const TORCHAUDIO_BLACKWELL_VERSION: &str = "2.8.0";
const INSTALL_LAYOUT_VERSION: &str = "3";
const SNDFILE_LINK_SOURCE: &str = "libsndfile_x86_64.so";
const SNDFILE_LINK_TARGET: &str = "libsndfile.so.1";
const SNDFILE_LINK_SCRIPT: &str = "import _soundfile_data as sd,os,sys,pathlib; src=pathlib.Path(sd.__file__).parent/sys.argv[1]; dst=pathlib.Path(sys.prefix)/sys.argv[2]/sys.argv[3]; os.makedirs(str(dst.parent),exist_ok=True); dst.unlink(missing_ok=True); dst.symlink_to(src); print(str(src)+sys.argv[4]+str(dst))";
const CUDA_RUNTIME_PACKAGES: &[&str] = &[
    "triton",
    "nvidia-nccl-cu12",
    "nvidia-cublas-cu12",
    "nvidia-cuda-cupti-cu12",
    "nvidia-cuda-nvrtc-cu12",
    "nvidia-cuda-runtime-cu12",
    "nvidia-cudnn-cu12",
    "nvidia-cufft-cu12",
    "nvidia-curand-cu12",
    "nvidia-cusolver-cu12",
    "nvidia-cusparse-cu12",
];

// ── Config ──────────────────────────────────────────────────────────────────

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OmniAsrConfig {
    pub runtime_root: PathBuf,
    pub worker_script_path: PathBuf,
    pub requirements_path: PathBuf,
    pub venv_path: PathBuf,
    pub models_dir: PathBuf,
    pub model: String,
    pub device: String,
    /// fairseq2 language code for LLM models (e.g. "eng_Latn").
    /// "auto" or empty string means no language conditioning (model auto-detects).
    pub lang: String,
    /// If true, all Python commands are routed through WSL2 (`wsl python3 ...`).
    /// Set automatically to `true` on Windows builds.
    pub use_wsl: bool,
    /// Linux-native path for the venv when running under WSL2.
    /// Must be on the WSL ext4 filesystem (NOT /mnt/c/...) so that
    /// PyTorch shared libraries (.so) can be loaded by the dynamic linker.
    pub wsl_venv_linux_path: String,
}

impl OmniAsrConfig {
    fn install_variant(&self) -> &'static str {
        if self.device.trim().eq_ignore_ascii_case("cuda") {
            detect_cuda_install_variant(self.use_wsl)
        } else {
            "cpu"
        }
    }

    fn install_stamp_contents(&self) -> String {
        format!(
            "{REQUIREMENTS}\n# variant={}\n# layout={INSTALL_LAYOUT_VERSION}",
            self.install_variant()
        )
    }

    /// The stamp file used on native (non-WSL) installs.
    pub fn install_stamp_path(&self) -> PathBuf {
        self.runtime_root.join("install.stamp")
    }

    /// The stamp file used on WSL2 installs.
    pub fn wsl_install_stamp_path(&self) -> PathBuf {
        self.runtime_root.join("wsl_install.stamp")
    }

    pub fn model_stamp_path(&self) -> PathBuf {
        let device = self
            .device
            .replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        let model = self
            .model
            .replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        self.runtime_root
            .join(format!("model-{model}-{device}.stamp"))
    }

    pub fn setup_lock_path(&self) -> PathBuf {
        self.runtime_root.join("setup.lock")
    }

    /// The Python binary path — only meaningful for native (non-WSL) installs.
    fn native_python_path(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv_path.join("Scripts").join("python.exe")
        } else {
            self.venv_path.join("bin").join("python3")
        }
    }

    pub fn ensure_files(&self) -> Result<(), String> {
        fs::create_dir_all(&self.runtime_root).map_err(|e| e.to_string())?;
        fs::create_dir_all(&self.models_dir).map_err(|e| e.to_string())?;
        fs::write(&self.worker_script_path, WORKER_SCRIPT).map_err(|e| e.to_string())?;
        fs::write(&self.requirements_path, REQUIREMENTS).map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn is_installed(&self) -> bool {
        let stamp_contents = self.install_stamp_contents();
        if self.use_wsl {
            self.wsl_install_stamp_path().exists()
                && fs::read_to_string(self.wsl_install_stamp_path())
                    .map(|c| c == stamp_contents)
                    .unwrap_or(false)
        } else {
            self.native_python_path().exists()
                && self.install_stamp_path().exists()
                && fs::read_to_string(self.install_stamp_path())
                    .map(|c| c == stamp_contents)
                    .unwrap_or(false)
        }
    }
}

/// Map a BCP-47 locale like `en-US` or a short ISO code like `en` to the
/// fairseq2 language code expected by Omni-ASR LLM models.
/// Returns an empty string for `auto` / unknown locales so the model
/// auto-detects instead.
pub fn locale_to_fairseq_lang(locale: &str) -> String {
    let trimmed = locale.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("auto") {
        return String::new();
    }

    if trimmed.contains('_') {
        return trimmed.to_string();
    }

    let primary = trimmed
        .split(['-', '_'])
        .next()
        .unwrap_or(trimmed)
        .to_ascii_lowercase();

    let code = match primary.as_str() {
        "en" | "eng" => "eng_Latn",
        "es" | "spa" => "spa_Latn",
        "fr" | "fra" => "fra_Latn",
        "de" | "deu" => "deu_Latn",
        "it" | "ita" => "ita_Latn",
        "pt" | "por" => "por_Latn",
        "nl" | "nld" => "nld_Latn",
        "pl" | "pol" => "pol_Latn",
        "ru" | "rus" => "rus_Cyrl",
        "zh" | "zho" => "zho_Hans",
        "ja" | "jpn" => "jpn_Jpan",
        "ko" | "kor" => "kor_Hang",
        "ar" | "ara" => "ara_Arab",
        "hi" | "hin" => "hin_Deva",
        "tr" | "tur" => "tur_Latn",
        "vi" | "vie" => "vie_Latn",
        "id" | "ind" => "ind_Latn",
        "sv" | "swe" => "swe_Latn",
        "da" | "dan" => "dan_Latn",
        "fi" | "fin" => "fin_Latn",
        "nb" | "nor" => "nob_Latn",
        "uk" | "ukr" => "ukr_Cyrl",
        "cs" | "ces" => "ces_Latn",
        "sk" | "slk" => "slk_Latn",
        "ro" | "ron" => "ron_Latn",
        "hu" | "hun" => "hun_Latn",
        "el" | "ell" => "ell_Grek",
        "he" | "heb" => "heb_Hebr",
        "th" | "tha" => "tha_Thai",
        _ => return String::new(),
    };

    code.to_string()
}

fn torch_index_for_variant(variant: &str) -> &'static str {
    match variant {
        "cu124" => PYTORCH_CUDA_INDEX,
        "cu128" => PYTORCH_CUDA_BLACKWELL_INDEX,
        _ => PYTORCH_CPU_INDEX,
    }
}

fn fairseq2_index_for_variant(variant: &str) -> &'static str {
    match variant {
        "cu124" => FAIRSEQ2_CUDA_INDEX,
        "cu128" => FAIRSEQ2_CUDA_BLACKWELL_INDEX,
        _ => FAIRSEQ2_CPU_INDEX,
    }
}

fn torch_version_for_variant(variant: &str) -> &'static str {
    if variant == "cu128" {
        TORCH_BLACKWELL_VERSION
    } else {
        TORCH_VERSION
    }
}

fn torchaudio_version_for_variant(variant: &str) -> &'static str {
    if variant == "cu128" {
        TORCHAUDIO_BLACKWELL_VERSION
    } else {
        TORCHAUDIO_VERSION
    }
}

fn cuda_variant_for_gpu_info(name: Option<&str>, compute_capability: Option<&str>) -> &'static str {
    if compute_capability
        .and_then(parse_compute_capability_major)
        .is_some_and(|major| major >= 10)
    {
        return "cu128";
    }

    if name.is_some_and(gpu_name_looks_blackwell) {
        return "cu128";
    }

    "cu124"
}

fn parse_compute_capability_major(compute_capability: &str) -> Option<u32> {
    compute_capability
        .trim()
        .split('.')
        .next()?
        .parse::<u32>()
        .ok()
}

fn gpu_name_looks_blackwell(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();

    if lower.contains("blackwell") {
        return true;
    }

    ["rtx 5050", "rtx 5060", "rtx 5070", "rtx 5080", "rtx 5090"]
        .iter()
        .any(|model| lower.contains(model))
}

fn forced_cuda_install_variant() -> Option<&'static str> {
    let value = std::env::var("OPENCASSAVA_OMNI_ASR_CUDA_VARIANT").ok()?;

    match value.trim().to_ascii_lowercase().as_str() {
        "cu124" | "legacy" => Some("cu124"),
        "cu128" | "blackwell" => Some("cu128"),
        _ => None,
    }
}

fn detect_cuda_install_variant(use_wsl: bool) -> &'static str {
    if let Some(variant) = forced_cuda_install_variant() {
        return variant;
    }

    static NATIVE_VARIANT: OnceLock<&'static str> = OnceLock::new();
    static WSL_VARIANT: OnceLock<&'static str> = OnceLock::new();

    let cell = if use_wsl {
        &WSL_VARIANT
    } else {
        &NATIVE_VARIANT
    };

    *cell.get_or_init(|| {
        let compute_capability = nvidia_smi_query("compute_cap", use_wsl);
        let name = nvidia_smi_query("name", use_wsl);

        cuda_variant_for_gpu_info(name.as_deref(), compute_capability.as_deref())
    })
}

fn nvidia_smi_query(field: &str, use_wsl: bool) -> Option<String> {
    let query = format!("--query-gpu={field}");

    command_output("nvidia-smi", &[query.as_str(), "--format=csv,noheader"]).or_else(|| {
        use_wsl
            .then(|| {
                command_output(
                    "wsl",
                    &["nvidia-smi", query.as_str(), "--format=csv,noheader"],
                )
            })
            .flatten()
    })
}

fn command_output(command: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(command).args(args).output().ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stdout.is_empty() {
        None
    } else {
        Some(stdout)
    }
}

fn native_ld_library_path(venv_path: &Path, existing: Option<&std::ffi::OsStr>) -> String {
    let mut value = venv_path.join("lib").to_string_lossy().into_owned();

    if let Some(existing) = existing {
        let existing = existing.to_string_lossy();
        if !existing.is_empty() {
            value.push(':');
            value.push_str(&existing);
        }
    }

    value
}

fn install_native_runtime_packages<F>(
    python_path: &Path,
    variant: &str,
    on_line: F,
) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    #[cfg(target_os = "linux")]
    {
        let torch_version = torch_version_for_variant(variant);
        let torchaudio_version = torchaudio_version_for_variant(variant);
        let torch_index = torch_index_for_variant(variant);
        let fairseq2_index = fairseq2_index_for_variant(variant);
        let is_cuda = variant.starts_with("cu");

        run_command(
            Command::new(python_path)
                .arg("-m")
                .arg("pip")
                .arg("install")
                .arg(format!("torch=={torch_version}"))
                .arg(format!("torchaudio=={torchaudio_version}"))
                .arg("--index-url")
                .arg(torch_index),
            if is_cuda {
                "install torch CUDA builds"
            } else {
                "install torch CPU builds"
            },
            on_line.clone(),
        )?;

        run_command(
            Command::new(python_path)
                .arg("-m")
                .arg("pip")
                .arg("install")
                .arg(format!("fairseq2=={FAIRSEQ2_VERSION}"))
                .arg("--extra-index-url")
                .arg(fairseq2_index),
            if is_cuda {
                "install fairseq2 CUDA"
            } else {
                "install fairseq2 CPU"
            },
            on_line,
        )?;
    }

    #[cfg(not(target_os = "linux"))]
    let _ = (variant, on_line);

    Ok(())
}

#[cfg(target_os = "linux")]
fn cleanup_native_cuda_packages<F>(python_path: &Path, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let mut command = Command::new(python_path);
    command.arg("-m").arg("pip").arg("uninstall").arg("-y");
    for package in CUDA_RUNTIME_PACKAGES {
        command.arg(package);
    }

    run_command(&mut command, "remove stray CUDA packages", on_line)
}

#[cfg(not(target_os = "linux"))]
fn cleanup_native_cuda_packages<F>(python_path: &Path, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let _ = (python_path, on_line);
    Ok(())
}

#[cfg(target_os = "linux")]
fn link_native_sndfile_for_fairseq2<F>(python_path: &Path, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    run_command(
        Command::new(python_path)
            .arg("-c")
            .arg(SNDFILE_LINK_SCRIPT)
            .arg(SNDFILE_LINK_SOURCE)
            .arg("lib")
            .arg(SNDFILE_LINK_TARGET)
            .arg(" -> "),
        "link libsndfile.so.1 for fairseq2",
        on_line,
    )
}

#[cfg(not(target_os = "linux"))]
fn link_native_sndfile_for_fairseq2<F>(python_path: &Path, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let _ = (python_path, on_line);
    Ok(())
}

// ── Path helpers for WSL2 ────────────────────────────────────────────────────

/// Convert a Windows path like `C:\Users\foo\bar` to a WSL path `/mnt/c/Users/foo/bar`.
fn to_wsl_path(path: &Path) -> String {
    let s = path.to_string_lossy();
    // Handle UNC paths and standard drive-letter paths.
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        return to_wsl_path(Path::new(rest));
    }
    if s.len() >= 2 && s.chars().nth(1) == Some(':') {
        let drive = s.chars().next().unwrap().to_ascii_lowercase();
        let rest = s[2..].replace('\\', "/");
        return format!("/mnt/{drive}{rest}");
    }
    // Already a Unix-style path (e.g. in tests or non-Windows builds).
    s.replace('\\', "/")
}

// ── WSL2 availability check ──────────────────────────────────────────────────

/// Check whether WSL2 is available and the default distro has Python 3.
/// Returns Ok(()) or Err with a human-readable message.
pub fn check_wsl2_available() -> Result<(), String> {
    // Step 1: Is `wsl` on PATH and does it respond?
    let wsl_status = Command::new("wsl")
        .args(["--status"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    match wsl_status {
        Err(_) => {
            return Err("WSL2 is not installed or not on PATH. \
            Install it with: wsl --install"
                .into())
        }
        Ok(s) if !s.success() => {
            return Err("WSL2 is installed but returned an error. \
            Make sure a Linux distribution is set as the default: wsl --set-default <distro>"
                .into())
        }
        Ok(_) => {}
    }

    // Step 2: Does the default distro have Python 3?
    let py_status = Command::new("wsl")
        .args(["python3", "--version"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    let py_ok = match py_status {
        Ok(s) => s.success(),
        Err(_) => false,
    };
    if !py_ok {
        return Err(
            "WSL2 is available but Python 3 was not found inside it. \
            In your WSL terminal run: sudo apt update && sudo apt install -y python3 python3-venv python3-pip".into()
        );
    }

    // Step 3: Is the `venv` module available inside WSL?
    // On Debian/Ubuntu python3-venv is a separate package that is often missing
    // even when python3 itself is installed.
    let venv_status = Command::new("wsl")
        .args(["python3", "-m", "venv", "--help"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    let venv_ok = match venv_status {
        Ok(s) => s.success(),
        Err(_) => false,
    };
    if !venv_ok {
        return Err("WSL2 has Python 3 but the 'venv' module is missing. \
            In your WSL terminal run: sudo apt install -y python3-venv python3-pip\n\
            (If your Python is 3.12, use: sudo apt install -y python3.12-venv)"
            .into());
    }

    Ok(())
}

// ── Native Python availability check ────────────────────────────────────────

/// Check whether a suitable Python 3 is available on the native system PATH.
/// Used by faster-whisper and parakeet on Windows (they do NOT use WSL2).
pub fn check_native_python_available() -> Result<String, String> {
    let mut found_unsupported_python_version: Option<String> = None;

    for candidate in native_python_candidates() {
        if let Some(version) = command_version(&candidate.command, &candidate.prefix_args) {
            if let Some(version) = unsupported_python_version(&version) {
                found_unsupported_python_version = Some(version);
                continue;
            }

            return Ok(candidate.display_command());
        }
    }

    if let Some(version) = found_unsupported_python_version {
        return Err(format!(
            "Python {version} is not supported for omni-asr. Install Python 3.10, 3.11, or 3.12."
        ));
    }

    if cfg!(windows) {
        Err("Python 3 is not installed on Windows. \
            Download it from https://python.org/downloads/ and make sure to check \
            'Add Python to PATH' during installation."
            .into())
    } else {
        Err(
            "Python 3 is not installed. Install it with your package manager, \
            e.g.: sudo apt install python3 python3-venv python3-pip"
                .into(),
        )
    }
}

// ── WSL venv path detection ──────────────────────────────────────────────────

/// Detect the WSL home directory and return the recommended Linux-native venv path.
/// The venv MUST live on the WSL ext4 filesystem (not /mnt/c/...) so that
/// PyTorch shared libraries can be loaded by the Linux dynamic linker.
pub fn detect_wsl_venv_linux_path() -> String {
    let home = Command::new("wsl")
        .args(["bash", "-c", "echo $HOME"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/tmp".to_string());
    format!("{home}/.local/share/opencassava/omni-asr/venv")
}

// ── Install runtime ──────────────────────────────────────────────────────────

pub fn install_runtime<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    config.ensure_files()?;

    if config.is_installed() {
        return Ok(());
    }

    let _lock = SetupLock::acquire(config)?;

    if config.use_wsl {
        // The WSL venv lives on the Linux-native filesystem — check and clean via WSL.
        let venv = &config.wsl_venv_linux_path;
        let stale = !venv.is_empty()
            && Command::new("wsl")
                .args(["bash", "-c", &format!("test -d '{venv}'")])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        if stale {
            on_line("[omni-asr] Removing stale virtual environment...");
            let _ = Command::new("wsl")
                .args(["bash", "-c", &format!("rm -rf '{venv}'")])
                .status();
        }
    } else if config.venv_path.exists() {
        on_line("[omni-asr] Removing stale virtual environment...");
        fs::remove_dir_all(&config.venv_path)
            .map_err(|e| format!("Failed to remove stale omni-asr environment: {e}"))?;
    }

    let result = if config.use_wsl {
        install_runtime_wsl(config, on_line)
    } else {
        install_runtime_native(config, on_line)
    };

    if let Err(e) = result {
        // Clean up the partial venv so next run starts fresh.
        if config.use_wsl {
            let venv = &config.wsl_venv_linux_path;
            if !venv.is_empty() {
                let _ = Command::new("wsl")
                    .args(["bash", "-c", &format!("rm -rf '{venv}'")])
                    .status();
            }
        } else if config.venv_path.exists() {
            let _ = fs::remove_dir_all(&config.venv_path);
        }
        return Err(e);
    }

    if config.use_wsl {
        fs::write(
            config.wsl_install_stamp_path(),
            config.install_stamp_contents(),
        )
        .map_err(|e| e.to_string())?;
    } else {
        fs::write(config.install_stamp_path(), config.install_stamp_contents())
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

fn install_runtime_native<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let python = detect_native_python()?;
    let install_variant = config.install_variant();

    if !config.native_python_path().exists() {
        run_command(
            Command::new(&python.command)
                .args(&python.prefix_args)
                .arg("-m")
                .arg("venv")
                .arg(&config.venv_path),
            "create omni-asr virtual environment",
            on_line.clone(),
        )?;
    }

    let python_path = config.native_python_path();
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("--upgrade")
            .arg("pip"),
        "upgrade pip for omni-asr",
        on_line.clone(),
    )?;
    install_native_runtime_packages(&python_path, install_variant, on_line.clone())?;

    #[cfg(target_os = "linux")]
    let fairseq2_index = fairseq2_index_for_variant(install_variant);

    #[cfg(target_os = "linux")]
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-r")
            .arg(&config.requirements_path)
            .arg("--extra-index-url")
            .arg(fairseq2_index),
        "install omni-asr runtime dependencies",
        on_line.clone(),
    )?;

    #[cfg(not(target_os = "linux"))]
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-r")
            .arg(&config.requirements_path),
        "install omni-asr runtime dependencies",
        on_line.clone(),
    )?;

    if install_variant == "cpu" {
        cleanup_native_cuda_packages(&python_path, on_line.clone())?;
    }

    link_native_sndfile_for_fairseq2(&python_path, on_line)?;

    Ok(())
}

fn install_runtime_wsl<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    if config.wsl_venv_linux_path.is_empty() {
        return Err("wsl_venv_linux_path is not set — cannot install omni-asr runtime.".into());
    }
    let venv_wsl = &config.wsl_venv_linux_path;
    let req_wsl = to_wsl_path(&config.requirements_path);
    let install_variant = config.install_variant();

    // 0. Pre-flight: verify python3-venv is available before doing anything.
    //    On Debian/Ubuntu python3-venv is a separate package from python3.
    //    We check quickly and fail early with a clear actionable message rather
    //    than auto-running sudo (which would block waiting for a password).
    on_line("[omni-asr] Checking python3-venv availability inside WSL...");
    let venv_avail = Command::new("wsl")
        .args(["python3", "-m", "venv", "--help"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if !venv_avail {
        return Err(concat!(
            "python3-venv is not installed inside WSL.\n",
            "Open your WSL terminal and run:\n",
            "  sudo apt update && sudo apt install -y python3-venv python3-pip\n\n",
            "On Ubuntu 24.04 with Python 3.12, use:\n",
            "  sudo apt install -y python3.12-venv python3-pip\n\n",
            "Then click 'Set up Omni-ASR' again."
        )
        .into());
    }
    on_line("[omni-asr] python3-venv is available.");

    // 1. Create venv inside WSL
    let create_venv_script = format!("python3 -m venv '{venv_wsl}' 2>&1 && echo 'venv created'");
    run_wsl_command(
        &create_venv_script,
        "create omni-asr WSL virtual environment",
        on_line.clone(),
    )?;

    // 2. Upgrade pip
    let upgrade_pip_script = format!("'{venv_wsl}/bin/python3' -m pip install --upgrade pip");
    run_wsl_command(
        &upgrade_pip_script,
        "upgrade pip for omni-asr (WSL)",
        on_line.clone(),
    )?;

    let torch_index = torch_index_for_variant(install_variant);
    let fairseq2_index = fairseq2_index_for_variant(install_variant);

    // 3. Pre-install torch + torchaudio from the selected PyTorch channel so
    //    omnilingual-asr does not pull an incompatible default wheel later on.
    let install_torch = format!(
        "'{venv_wsl}/bin/python3' -m pip install \
         torch=={} torchaudio=={} \
         --index-url {torch_index}",
        torch_version_for_variant(install_variant),
        torchaudio_version_for_variant(install_variant)
    );
    run_wsl_command(
        &install_torch,
        if install_variant.starts_with("cu") {
            "install torch CUDA builds (WSL)"
        } else {
            "install torch CPU builds (WSL)"
        },
        on_line.clone(),
    )?;

    // 4. Pre-install fairseq2 from the matching Meta index so fairseq2n pulls
    //    the native extension built for the selected torch/CUDA stack.
    let install_fairseq2 = format!(
        "'{venv_wsl}/bin/python3' -m pip install 'fairseq2=={FAIRSEQ2_VERSION}' \
         --extra-index-url {fairseq2_index}"
    );
    run_wsl_command(
        &install_fairseq2,
        if install_variant.starts_with("cu") {
            "install fairseq2 CUDA (WSL)"
        } else {
            "install fairseq2 CPU (WSL)"
        },
        on_line.clone(),
    )?;

    // 5. Install all requirements. torch/torchaudio are already installed for the CPU
    //    variant, so pip will keep them and only fetch the remaining packages from PyPI.
    let install_req_script = format!(
        "'{venv_wsl}/bin/python3' -m pip install -r '{req_wsl}' \
         --extra-index-url {fairseq2_index}"
    );
    run_wsl_command(
        &install_req_script,
        "install omni-asr dependencies (WSL)",
        on_line.clone(),
    )?;

    if install_variant == "cpu" {
        // 6 (CPU). Best-effort cleanup of stray CUDA packages.
        let cleanup_cuda_script = format!(
            "'{venv_wsl}/bin/python3' -m pip uninstall -y \
             {} 2>/dev/null; exit 0",
            CUDA_RUNTIME_PACKAGES.join(" ")
        );
        run_wsl_command(
            &cleanup_cuda_script,
            "remove stray CUDA packages (WSL)",
            on_line.clone(),
        )?;
    }

    // 7. Create libsndfile.so.1 symlink inside the venv so fairseq2n can dlopen it.
    //    soundfile bundles libsndfile_x86_64.so but fairseq2n looks for libsndfile.so.1.
    //    Filenames are passed as sys.argv to avoid any quoting issues.
    let link_sndfile_script = format!(
        "'{venv_wsl}/bin/python3' -c \
         '{SNDFILE_LINK_SCRIPT}' \
         {SNDFILE_LINK_SOURCE} lib {SNDFILE_LINK_TARGET} ' -> '"
    );
    run_wsl_command(
        &link_sndfile_script,
        "link libsndfile.so.1 for fairseq2 (WSL)",
        on_line.clone(),
    )?;

    Ok(())
}

fn run_wsl_command<F>(bash_script: &str, description: &str, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    log::info!("[omni-asr] Starting {description} (WSL)");
    run_command(
        Command::new("wsl").arg("bash").arg("-c").arg(bash_script),
        description,
        on_line,
    )
}

// ── Health check ─────────────────────────────────────────────────────────────

pub fn health_check(config: &OmniAsrConfig) -> Result<(), String> {
    health_check_with_log(config, |_| {})
}

pub fn health_check_with_log<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + 'static,
{
    if config.use_wsl {
        check_wsl2_available()?;
    }
    if config.setup_lock_path().exists() {
        if config.is_installed() {
            // Stale lock left by a crashed install — safe to remove.
            let _ = fs::remove_file(config.setup_lock_path());
        } else {
            return Err("omni-asr setup is still running.".into());
        }
    }
    if !config.is_installed() {
        return Err("omni-asr runtime is not installed.".into());
    }
    let mut worker = OmniAsrWorker::spawn_with_log(config, on_line)?;
    worker.health()?;
    let _ = worker.shutdown();
    Ok(())
}

// ── Ensure model ─────────────────────────────────────────────────────────────

pub fn ensure_model<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + 'static,
{
    if !config.is_installed() {
        install_runtime(config, |_| {})?;
    }
    let mut worker = OmniAsrWorker::spawn_with_log(config, on_line)?;
    worker.ensure_model()?;
    fs::write(config.model_stamp_path(), &config.model).map_err(|e| e.to_string())?;
    let _ = worker.shutdown();
    Ok(())
}

// ── Worker ───────────────────────────────────────────────────────────────────

pub struct OmniAsrWorker {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    stderr_tail: Arc<Mutex<String>>,
    config: OmniAsrConfig,
}

impl OmniAsrWorker {
    pub fn spawn(config: &OmniAsrConfig) -> Result<Self, String> {
        Self::spawn_with_log(config, |_| {})
    }

    pub fn spawn_with_log<F>(config: &OmniAsrConfig, on_line: F) -> Result<Self, String>
    where
        F: Fn(&str) + Send + 'static,
    {
        config.ensure_files()?;
        if !config.is_installed() {
            return Err("omni-asr runtime is not installed.".into());
        }

        let mut child = if config.use_wsl {
            Self::spawn_wsl(config)?
        } else {
            Self::spawn_native(config)?
        };

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Failed to open stdin for omni-asr worker.".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to open stdout for omni-asr worker.".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Failed to open stderr for omni-asr worker.".to_string())?;

        let stderr_tail = Arc::new(Mutex::new(String::new()));
        pump_stderr(stderr, Arc::clone(&stderr_tail), on_line);

        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            stderr_tail,
            config: config.clone(),
        })
    }

    fn spawn_native(config: &OmniAsrConfig) -> Result<Child, String> {
        let mut command = Command::new(config.native_python_path());
        command
            .arg("-u")
            .arg(&config.worker_script_path)
            .env("HF_HUB_DISABLE_PROGRESS_BARS", "0")
            .env("TQDM_FORCE", "1");

        #[cfg(target_os = "linux")]
        command.env(
            "LD_LIBRARY_PATH",
            native_ld_library_path(
                &config.venv_path,
                std::env::var_os("LD_LIBRARY_PATH").as_deref(),
            ),
        );

        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to launch omni-asr worker: {e}"))
    }

    fn spawn_wsl(config: &OmniAsrConfig) -> Result<Child, String> {
        let venv_wsl = &config.wsl_venv_linux_path;
        let script_wsl = to_wsl_path(&config.worker_script_path);
        // Pass the Windows-translated models dir into WSL as an env var the worker can use.
        let models_wsl = to_wsl_path(&config.models_dir);

        Command::new("wsl")
            .arg("bash")
            .arg("-c")
            .arg(format!(
                "LD_LIBRARY_PATH='{venv_wsl}/lib' \
                 HF_HUB_DISABLE_PROGRESS_BARS=0 TQDM_FORCE=1 \
                 OMNI_ASR_MODELS_DIR='{models_wsl}' \
                 '{venv_wsl}/bin/python3' -u '{script_wsl}'"
            ))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to launch omni-asr WSL worker: {e}"))
    }

    pub fn health(&mut self) -> Result<(), String> {
        self.send_request(json!({ "command": "health" }))?;
        Ok(())
    }

    pub fn ensure_model(&mut self) -> Result<(), String> {
        self.send_request(json!({
            "command": "ensure_model",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
        }))?;
        Ok(())
    }

    pub fn transcribe(&mut self, samples: &[f32], language: &str) -> Result<String, String> {
        let request_lang = locale_to_fairseq_lang(language);
        let lang = if request_lang.is_empty() {
            self.config.lang.trim()
        } else {
            request_lang.as_str()
        };
        let lang_value = if lang.is_empty() || lang == "auto" {
            serde_json::Value::Null
        } else {
            serde_json::Value::String(lang.to_string())
        };
        let response = self.send_request(json!({
            "command": "transcribe",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
            "lang": lang_value,
            "samples": samples,
        }))?;
        Ok(response["text"].as_str().unwrap_or_default().to_string())
    }

    pub fn shutdown(&mut self) -> Result<(), String> {
        let _ = self.send_request(json!({ "command": "shutdown" }));
        let _ = self.child.wait();
        Ok(())
    }

    fn send_request(&mut self, payload: serde_json::Value) -> Result<serde_json::Value, String> {
        let line = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
        self.stdin
            .write_all(line.as_bytes())
            .and_then(|_| self.stdin.write_all(b"\n"))
            .and_then(|_| self.stdin.flush())
            .map_err(|e| format!("Failed to write to omni-asr worker: {e}"))?;

        let mut response = String::new();
        self.stdout
            .read_line(&mut response)
            .map_err(|e| format!("Failed to read omni-asr worker response: {e}"))?;
        if response.trim().is_empty() {
            let stderr = self.stderr_snapshot();
            let status = self.child.try_wait().ok().flatten();
            return Err(format_worker_exit_error(status, &stderr));
        }
        let json: serde_json::Value = serde_json::from_str(response.trim())
            .map_err(|e| format!("Invalid omni-asr worker response: {e}"))?;
        if json["ok"].as_bool().unwrap_or(false) {
            Ok(json["result"].clone())
        } else {
            Err(json["error"]
                .as_str()
                .unwrap_or("Unknown omni-asr worker error.")
                .to_string())
        }
    }

    fn stderr_snapshot(&self) -> String {
        self.stderr_tail
            .lock()
            .map(|v| v.trim().to_string())
            .unwrap_or_default()
    }
}

impl Drop for OmniAsrWorker {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn pump_stderr<F>(mut stderr: impl Read + Send + 'static, tail: Arc<Mutex<String>>, on_line: F)
where
    F: Fn(&str) + Send + 'static,
{
    thread::spawn(move || {
        let mut line_buf = String::new();
        let mut buf = [0u8; 1024];
        loop {
            match stderr.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let text = String::from_utf8_lossy(&buf[..n]);
                    for c in text.chars() {
                        if c == '\n' || c == '\r' {
                            // Trim trailing whitespace — progress bars pad with spaces
                            // to overwrite longer previous lines when using \r.
                            let trimmed = line_buf.trim_end().to_string();
                            line_buf.clear();
                            if !trimmed.is_empty() {
                                log::warn!("[omni-asr] {trimmed}");
                                on_line(&trimmed);
                                if let Ok(mut tail_buf) = tail.lock() {
                                    if !tail_buf.is_empty() {
                                        tail_buf.push('\n');
                                    }
                                    tail_buf.push_str(&trimmed);
                                    if tail_buf.len() > 4000 {
                                        let start = tail_buf.len().saturating_sub(4000);
                                        // Snap to the next valid char boundary so we
                                        // don't split a multi-byte UTF-8 sequence.
                                        let start = tail_buf
                                            .char_indices()
                                            .map(|(i, _)| i)
                                            .find(|&i| i >= start)
                                            .unwrap_or(tail_buf.len());
                                        *tail_buf = tail_buf[start..].to_string();
                                    }
                                }
                            }
                        } else {
                            line_buf.push(c);
                        }
                    }
                }
                Err(_) => break,
            }
        }
    });
}

fn format_worker_exit_error(status: Option<std::process::ExitStatus>, stderr: &str) -> String {
    let mut message = "omni-asr worker exited without a response.".to_string();
    if let Some(status) = status {
        message.push_str(&format!(" Exit status: {status}."));
    }
    if !stderr.is_empty() {
        message.push_str(" Worker stderr: ");
        message.push_str(stderr);
    }
    message
}

fn run_command<F>(command: &mut Command, description: &str, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    log::info!("[omni-asr] Starting {description}");
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to {description}: {e}"))?;

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let on_line_stdout = on_line.clone();
    let stdout_thread = thread::spawn(move || {
        let mut stdout = stdout;
        let mut buf_all = Vec::new();
        let mut line_buf = String::new();
        let mut buf = [0u8; 1024];
        loop {
            match stdout.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    buf_all.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&buf[..n]);
                    for c in text.chars() {
                        if c == '\n' || c == '\r' {
                            if !line_buf.is_empty() {
                                log::info!("[omni-asr] {}", line_buf);
                                on_line_stdout(&line_buf);
                                line_buf.clear();
                            }
                        } else {
                            line_buf.push(c);
                        }
                    }
                }
                Err(_) => break,
            }
        }
        buf_all
    });
    let stderr_thread = thread::spawn(move || {
        let mut stderr = stderr;
        let mut buf_all = Vec::new();
        let mut line_buf = String::new();
        let mut buf = [0u8; 1024];
        loop {
            match stderr.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    buf_all.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&buf[..n]);
                    for c in text.chars() {
                        if c == '\n' || c == '\r' {
                            if !line_buf.is_empty() {
                                log::info!("[omni-asr] {}", line_buf);
                                on_line(&line_buf);
                                line_buf.clear();
                            }
                        } else {
                            line_buf.push(c);
                        }
                    }
                }
                Err(_) => break,
            }
        }
        buf_all
    });

    let status = child
        .wait()
        .map_err(|e| format!("Failed to wait for {description}: {e}"))?;
    let stdout_buf = stdout_thread.join().unwrap_or_default();
    let stderr_buf = stderr_thread.join().unwrap_or_default();

    if status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&stderr_buf);
    let stdout = String::from_utf8_lossy(&stdout_buf);
    let mut message = format!("Failed to {description}.");
    if !stderr.trim().is_empty() {
        message.push_str(" stderr: ");
        message.push_str(stderr.trim());
    }
    if !stdout.trim().is_empty() {
        message.push_str(" stdout: ");
        message.push_str(stdout.trim());
    }
    Err(message)
}

struct SetupLock {
    path: PathBuf,
}

impl SetupLock {
    fn acquire(config: &OmniAsrConfig) -> Result<Self, String> {
        fs::write(config.setup_lock_path(), "installing").map_err(|e| e.to_string())?;
        Ok(Self {
            path: config.setup_lock_path(),
        })
    }
}

impl Drop for SetupLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Debug)]
struct PythonCandidate {
    command: String,
    prefix_args: Vec<String>,
}

impl PythonCandidate {
    fn display_command(&self) -> String {
        format!("{} {}", self.command, self.prefix_args.join(" "))
            .trim()
            .to_string()
    }
}

fn native_python_candidates() -> Vec<PythonCandidate> {
    if cfg!(windows) {
        vec![
            PythonCandidate {
                command: "py".into(),
                prefix_args: vec!["-3".into()],
            },
            PythonCandidate {
                command: "python".into(),
                prefix_args: vec![],
            },
        ]
    } else {
        vec![
            PythonCandidate {
                command: "python3".into(),
                prefix_args: vec![],
            },
            PythonCandidate {
                command: "python3.12".into(),
                prefix_args: vec![],
            },
            PythonCandidate {
                command: "python3.11".into(),
                prefix_args: vec![],
            },
            PythonCandidate {
                command: "python3.10".into(),
                prefix_args: vec![],
            },
            PythonCandidate {
                command: "python".into(),
                prefix_args: vec![],
            },
        ]
    }
}

fn unsupported_python_version(version: &str) -> Option<String> {
    let version = version.strip_prefix("Python ")?;
    let mut parts = version.split('.');
    let major = parts.next()?.parse::<u32>().ok()?;
    let minor = parts.next()?.parse::<u32>().ok()?;

    if major == 3 && (10..=12).contains(&minor) {
        None
    } else {
        Some(format!("{major}.{minor}"))
    }
}

fn detect_native_python() -> Result<PythonCandidate, String> {
    let mut found_unsupported_python_version: Option<String> = None;

    for candidate in native_python_candidates() {
        if let Some(version) = command_version(&candidate.command, &candidate.prefix_args) {
            if let Some(version) = unsupported_python_version(&version) {
                found_unsupported_python_version = Some(version);
                continue;
            }

            return Ok(candidate);
        }
    }

    if let Some(version) = found_unsupported_python_version {
        return Err(format!(
            "Python {version} is not supported for omni-asr. Install Python 3.10, 3.11, or 3.12."
        ));
    }

    Err("Python 3 was not found. Install Python 3 to enable omni-asr.".into())
}

fn command_version(command: &str, prefix_args: &[String]) -> Option<String> {
    let output = Command::new(command)
        .args(prefix_args)
        .arg("--version")
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stdout.is_empty() {
        return Some(stdout);
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return Some(stderr);
    }

    None
}

pub fn model_storage_exists(config: &OmniAsrConfig) -> bool {
    config.model_stamp_path().exists()
}

#[cfg(test)]
mod tests {
    use super::{
        check_native_python_available, cuda_variant_for_gpu_info, detect_native_python,
        fairseq2_index_for_variant, install_native_runtime_packages, locale_to_fairseq_lang,
        native_ld_library_path, OmniAsrConfig, FAIRSEQ2_CPU_INDEX, FAIRSEQ2_CUDA_BLACKWELL_INDEX,
        FAIRSEQ2_CUDA_INDEX, INSTALL_LAYOUT_VERSION, REQUIREMENTS,
    };
    use std::ffi::OsStr;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};
    use tempfile::tempdir;

    fn path_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn locale_conversions() {
        assert_eq!(locale_to_fairseq_lang("en-US"), "eng_Latn");
        assert_eq!(locale_to_fairseq_lang("eng_Latn"), "eng_Latn");
        assert_eq!(locale_to_fairseq_lang("auto"), "");
        assert_eq!(locale_to_fairseq_lang(""), "");
    }

    #[test]
    fn variant_indexes() {
        assert_eq!(fairseq2_index_for_variant("cpu"), FAIRSEQ2_CPU_INDEX);
        assert_eq!(fairseq2_index_for_variant("cu124"), FAIRSEQ2_CUDA_INDEX);
        assert_eq!(
            fairseq2_index_for_variant("cu128"),
            FAIRSEQ2_CUDA_BLACKWELL_INDEX
        );
    }

    #[test]
    fn picks_blackwell_cuda_stack_only_for_new_gpus() {
        assert_eq!(
            cuda_variant_for_gpu_info(Some("NVIDIA GeForce RTX 5090 Laptop GPU"), None),
            "cu128"
        );
        assert_eq!(cuda_variant_for_gpu_info(None, Some("12.0")), "cu128");
        assert_eq!(
            cuda_variant_for_gpu_info(Some("NVIDIA RTX 5000 Ada Generation"), None),
            "cu124"
        );
        assert_eq!(cuda_variant_for_gpu_info(None, Some("8.9")), "cu124");
    }

    #[test]
    #[cfg(not(target_os = "windows"))]
    fn ld_library_path() {
        let venv = PathBuf::from("/tmp/venv");
        assert_eq!(native_ld_library_path(&venv, None), "/tmp/venv/lib");
        assert_eq!(
            native_ld_library_path(&venv, Some(OsStr::new("/usr/lib"))),
            "/tmp/venv/lib:/usr/lib"
        );
    }

    #[test]
    fn stamp_layout_tracking() {
        let config = OmniAsrConfig {
            runtime_root: PathBuf::from("/tmp/runtime"),
            worker_script_path: PathBuf::from("/tmp/runtime/worker.py"),
            requirements_path: PathBuf::from("/tmp/runtime/requirements.txt"),
            venv_path: PathBuf::from("/tmp/runtime/venv"),
            models_dir: PathBuf::from("/tmp/runtime/models"),
            model: "omniASR_CTC_300M".into(),
            device: "cpu".into(),
            lang: String::new(),
            use_wsl: false,
            wsl_venv_linux_path: String::new(),
        };
        assert!(config
            .install_stamp_contents()
            .contains(&format!("# layout={INSTALL_LAYOUT_VERSION}")));
    }

    #[test]
    fn rejects_old_layout_stamp() {
        let tempdir = tempdir().unwrap();
        let runtime_root = tempdir.path().join("runtime");
        let venv_path = runtime_root.join("venv");
        let python_path = venv_path.join("bin").join("python3");
        fs::create_dir_all(python_path.parent().unwrap()).unwrap();
        fs::write(&python_path, "").unwrap();

        let config = OmniAsrConfig {
            runtime_root: runtime_root.clone(),
            worker_script_path: runtime_root.join("worker.py"),
            requirements_path: runtime_root.join("requirements.txt"),
            venv_path,
            models_dir: runtime_root.join("models"),
            model: "omniASR_CTC_300M".into(),
            device: "cuda".into(),
            lang: String::new(),
            use_wsl: false,
            wsl_venv_linux_path: String::new(),
        };
        fs::write(
            config.install_stamp_path(),
            format!("{REQUIREMENTS}\n# variant=cu124\n# layout=2"),
        )
        .unwrap();
        assert!(!config.is_installed());
    }

    #[cfg(unix)]
    #[test]
    fn pip_install_commands_cuda_variants() {
        fn record_commands(variant: &str) -> String {
            let tempdir = tempdir().unwrap();
            let python_path = tempdir.path().join("python3");
            let log_path = tempdir.path().join("commands.log");
            fs::write(&log_path, "").unwrap();

            let script_path = tempdir.path().join("python3");
            fs::write(
                &script_path,
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$OMNI_ASR_TEST_LOG\"\nexit 0\n",
            )
            .unwrap();
            let mut perms = fs::metadata(&script_path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms).unwrap();

            std::env::set_var("OMNI_ASR_TEST_LOG", &log_path);
            install_native_runtime_packages(&python_path, variant, |_| {}).unwrap();
            std::env::remove_var("OMNI_ASR_TEST_LOG");

            fs::read_to_string(&log_path).unwrap()
        }

        let legacy_commands = record_commands("cu124");
        assert!(legacy_commands.contains("torch==2.6.0"));
        assert!(legacy_commands.contains("https://download.pytorch.org/whl/cu124"));
        assert!(legacy_commands.contains("https://fair.pkg.atmeta.com/fairseq2/whl/pt2.6.0/cu124"));

        let blackwell_commands = record_commands("cu128");
        assert!(blackwell_commands.contains("torch==2.8.0"));
        assert!(blackwell_commands.contains("https://download.pytorch.org/whl/cu128"));
        assert!(
            blackwell_commands.contains("https://fair.pkg.atmeta.com/fairseq2/whl/pt2.8.0/cu128")
        );
    }

    #[cfg(unix)]
    mod python_detection {
        use super::*;
        use std::env;
        use std::ffi::OsString;
        use std::path::Path;

        struct PathGuard(Option<OsString>);
        impl PathGuard {
            fn set(path: &Path) -> Self {
                let original = env::var_os("PATH");
                env::set_var("PATH", path);
                Self(original)
            }
        }
        impl Drop for PathGuard {
            fn drop(&mut self) {
                match self.0.take() {
                    Some(p) => env::set_var("PATH", p),
                    None => env::remove_var("PATH"),
                }
            }
        }

        fn write_python(dir: &Path, name: &str, version: Option<&str>) {
            let content = match version {
                Some(v) => format!("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\necho '{v}'\nexit 0\nfi\nexit 1\n"),
                None => "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then exit 0; fi\nexit 1\n".into(),
            };
            let path = dir.join(name);
            fs::write(&path, content).unwrap();
            let mut perms = fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&path, perms).unwrap();
        }

        fn run_test(cases: &[(&str, Option<&str>)]) -> (tempfile::TempDir, PathGuard) {
            let _guard = path_lock().lock().unwrap();
            let td = tempdir().unwrap();
            for (name, ver) in cases {
                write_python(td.path(), name, *ver);
            }
            let guard = PathGuard::set(td.path());
            (td, guard)
        }

        #[test]
        fn selects_supported_python() {
            let (_td, _guard) = run_test(&[
                ("python3", Some("Python 3.13.0")),
                ("python", Some("Python 3.12.9")),
            ]);
            assert_eq!(detect_native_python().unwrap().command, "python");
            assert_eq!(check_native_python_available().unwrap(), "python");
        }

        #[test]
        fn selects_versioned_python() {
            let (_td, _guard) = run_test(&[("python3.11", Some("Python 3.11.11"))]);
            assert_eq!(detect_native_python().unwrap().command, "python3.11");
        }

        #[test]
        fn rejects_unsupported_version() {
            let (_td, _guard) = run_test(&[("python3", Some("Python 3.13.0"))]);
            assert!(detect_native_python().unwrap_err().contains("3.13"));
            assert!(check_native_python_available()
                .unwrap_err()
                .contains("3.13"));
        }

        #[test]
        fn rejects_old_version() {
            let (_td, _guard) = run_test(&[("python3", Some("Python 3.9.0"))]);
            assert!(detect_native_python().unwrap_err().contains("3.9"));
        }

        #[test]
        fn prefers_explicit_versions() {
            let (_td, _guard) = run_test(&[
                ("python3", Some("Python 3.13.0")),
                ("python3.10", Some("Python 3.10.0")),
            ]);
            assert_eq!(detect_native_python().unwrap().command, "python3.10");
        }

        #[test]
        fn skips_commands_without_version() {
            let (_td, _guard) =
                run_test(&[("python3", None), ("python3.12", Some("Python 3.12.0"))]);
            assert_eq!(detect_native_python().unwrap().command, "python3.12");
        }
    }
}
