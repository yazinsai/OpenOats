use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

const WORKER_SCRIPT: &str = include_str!("omni_asr_worker.py");
const REQUIREMENTS: &str = include_str!("omni_asr_requirements.txt");
const PYTORCH_CPU_INDEX: &str = "https://download.pytorch.org/whl/cpu";
const PYTORCH_CUDA_INDEX: &str = "https://download.pytorch.org/whl/cu124";
const FAIRSEQ2_CPU_INDEX: &str = "https://fair.pkg.atmeta.com/fairseq2/whl/pt2.6.0/cpu";
const FAIRSEQ2_CUDA_INDEX: &str = "https://fair.pkg.atmeta.com/fairseq2/whl/pt2.6.0/cu124";

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
            "cu124"
        } else {
            "cpu"
        }
    }

    fn install_stamp_contents(&self) -> String {
        format!("{REQUIREMENTS}\n# variant={}", self.install_variant())
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

fn install_native_runtime_packages<F>(
    _python_path: &Path,
    variant: &str,
    on_line: F,
) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    // Only add the fairseq2 index — torch version is driven by omnilingual-asr's deps.
    #[cfg(target_os = "linux")]
    {
        let fairseq2_index = if variant == "cu124" {
            FAIRSEQ2_CUDA_INDEX
        } else {
            FAIRSEQ2_CPU_INDEX
        };
        run_command(
            Command::new(python_path)
                .arg("-m")
                .arg("pip")
                .arg("install")
                .arg("fairseq2")
                .arg("--extra-index-url")
                .arg(fairseq2_index),
            &format!("install fairseq2 runtime ({variant})"),
            on_line,
        )?;
    }

    #[cfg(not(target_os = "linux"))]
    let _ = (variant, on_line);

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
    let candidates: &[(&str, &[&str])] = if cfg!(windows) {
        &[("py", &["-3"]), ("python", &[])]
    } else {
        &[("python3", &[]), ("python", &[])]
    };

    for (cmd, args) in candidates {
        let ok = Command::new(cmd)
            .args(args.iter())
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return Ok(format!("{} {}", cmd, args.join(" ")).trim().to_string());
        }
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
    install_native_runtime_packages(&python_path, config.install_variant(), on_line.clone())?;
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-r")
            .arg(&config.requirements_path),
        "install omni-asr runtime dependencies",
        on_line,
    )?;

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

    let torch_index = if install_variant == "cu124" {
        PYTORCH_CUDA_INDEX
    } else {
        PYTORCH_CPU_INDEX
    };
    let fairseq2_index = if install_variant == "cu124" {
        FAIRSEQ2_CUDA_INDEX
    } else {
        FAIRSEQ2_CPU_INDEX
    };

    if install_variant != "cu124" {
        // 3 (CPU). Pre-install torch + torchaudio from the CPU index BEFORE omnilingual-asr
        //          can pull CUDA builds from PyPI. pip will not re-download them when
        //          resolving requirements as long as the installed version satisfies the
        //          omnilingual-asr constraint.
        //          fairseq2 pt2.6.0 requires torch 2.6.x so we pin that version.
        let install_torch_cpu = format!(
            "'{venv_wsl}/bin/python3' -m pip install \
             torch==2.6.0 torchaudio==2.6.0 \
             --index-url {torch_index}"
        );
        run_wsl_command(
            &install_torch_cpu,
            "install torch CPU builds (WSL)",
            on_line.clone(),
        )?;

        // 4 (CPU). Pre-install fairseq2==0.6 from the Meta index.
        let install_fairseq2 = format!(
            "'{venv_wsl}/bin/python3' -m pip install 'fairseq2==0.6' \
             --extra-index-url {fairseq2_index}"
        );
        run_wsl_command(
            &install_fairseq2,
            "install fairseq2 CPU (WSL)",
            on_line.clone(),
        )?;
    } else {
        // 3 (CUDA). Pre-install fairseq2==0.6 from the CUDA Meta index.
        let install_fairseq2 = format!(
            "'{venv_wsl}/bin/python3' -m pip install 'fairseq2==0.6' \
             --extra-index-url {fairseq2_index}"
        );
        run_wsl_command(
            &install_fairseq2,
            "install fairseq2 CUDA (WSL)",
            on_line.clone(),
        )?;
    }

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

    if install_variant != "cu124" {
        // 6 (CPU). Best-effort cleanup of stray CUDA packages.
        let cleanup_cuda_script = format!(
            "'{venv_wsl}/bin/python3' -m pip uninstall -y \
             triton nvidia-nccl-cu12 nvidia-cublas-cu12 nvidia-cuda-cupti-cu12 \
             nvidia-cuda-nvrtc-cu12 nvidia-cuda-runtime-cu12 nvidia-cudnn-cu12 \
             nvidia-cufft-cu12 nvidia-curand-cu12 nvidia-cusolver-cu12 \
             nvidia-cusparse-cu12 2>/dev/null; exit 0"
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
         'import _soundfile_data as sd,os,sys,pathlib; \
          src=pathlib.Path(sd.__file__).parent/sys.argv[1]; \
          dst=pathlib.Path(sys.prefix)/sys.argv[2]/sys.argv[3]; \
          os.makedirs(str(dst.parent),exist_ok=True); \
          dst.unlink(missing_ok=True); \
          dst.symlink_to(src); \
          print(str(src)+sys.argv[4]+str(dst))' \
         libsndfile_x86_64.so lib libsndfile.so.1 ' -> '"
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
        Command::new(config.native_python_path())
            .arg("-u")
            .arg(&config.worker_script_path)
            .env("HF_HUB_DISABLE_PROGRESS_BARS", "0")
            .env("TQDM_FORCE", "1")
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

struct PythonCandidate {
    command: String,
    prefix_args: Vec<String>,
}

fn detect_native_python() -> Result<PythonCandidate, String> {
    let candidates = if cfg!(windows) {
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
                command: "python".into(),
                prefix_args: vec![],
            },
        ]
    };

    for candidate in candidates {
        if command_works(&candidate.command, &candidate.prefix_args) {
            return Ok(candidate);
        }
    }

    Err("Python 3 was not found. Install Python 3 to enable omni-asr.".into())
}

fn command_works(command: &str, prefix_args: &[String]) -> bool {
    Command::new(command)
        .args(prefix_args)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

pub fn model_storage_exists(config: &OmniAsrConfig) -> bool {
    config.model_stamp_path().exists()
}

#[cfg(test)]
mod tests {
    use super::locale_to_fairseq_lang;

    #[test]
    fn maps_bcp47_locales_to_fairseq_codes() {
        assert_eq!(locale_to_fairseq_lang("en-US"), "eng_Latn");
        assert_eq!(locale_to_fairseq_lang("es-ES"), "spa_Latn");
        assert_eq!(locale_to_fairseq_lang("pt-BR"), "por_Latn");
    }

    #[test]
    fn preserves_existing_fairseq_codes() {
        assert_eq!(locale_to_fairseq_lang("eng_Latn"), "eng_Latn");
        assert_eq!(locale_to_fairseq_lang("ara_Arab"), "ara_Arab");
    }

    #[test]
    fn unknown_or_auto_locale_falls_back_to_auto_detect() {
        assert_eq!(locale_to_fairseq_lang("auto"), "");
        assert_eq!(locale_to_fairseq_lang(""), "");
        assert_eq!(locale_to_fairseq_lang("xx-YY"), "");
    }
}
