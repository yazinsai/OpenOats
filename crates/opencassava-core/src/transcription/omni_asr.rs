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
const TORCH_VERSION: &str = "2.6.0";
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
    /// If true, all Python commands are routed through WSL2 (`wsl python3 ...`).
    /// Set automatically to `true` on Windows builds.
    pub use_wsl: bool,
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
        let device = self.device.replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        let model = self.model.replace(|c: char| !c.is_ascii_alphanumeric(), "_");
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

fn install_wsl_runtime_packages<F>(
    venv_wsl: &str,
    variant: &str,
    on_line: F,
) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let fairseq2_index = if variant == "cu124" {
        FAIRSEQ2_CUDA_INDEX
    } else {
        FAIRSEQ2_CPU_INDEX
    };
    let install_script = format!(
        "{venv_wsl}/bin/python3 -m pip install torch=={TORCH_VERSION} && \
         {venv_wsl}/bin/python3 -m pip install fairseq2 --extra-index-url {fairseq2_index}"
    );
    run_wsl_command(
        &install_script,
        &format!("install torch/fairseq2 runtime ({variant}, WSL)"),
        on_line,
    )
}

fn install_native_runtime_packages<F>(
    python_path: &Path,
    variant: &str,
    on_line: F,
) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    run_command(
        Command::new(python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg(format!("torch=={TORCH_VERSION}")),
        &format!("install torch runtime ({variant})"),
        on_line.clone(),
    )?;

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
        Err(_) => return Err(
            "WSL2 is not installed or not on PATH. \
            Install it with: wsl --install".into()
        ),
        Ok(s) if !s.success() => return Err(
            "WSL2 is installed but returned an error. \
            Make sure a Linux distribution is set as the default: wsl --set-default <distro>".into()
        ),
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
        return Err(
            "WSL2 has Python 3 but the 'venv' module is missing. \
            In your WSL terminal run: sudo apt install -y python3-venv python3-pip\n\
            (If your Python is 3.12, use: sudo apt install -y python3.12-venv)".into()
        );
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
            'Add Python to PATH' during installation.".into())
    } else {
        Err("Python 3 is not installed. Install it with your package manager, \
            e.g.: sudo apt install python3 python3-venv python3-pip".into())
    }
}

// ── Install runtime ──────────────────────────────────────────────────────────

pub fn install_runtime<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    config.ensure_files()?;
    let _lock = SetupLock::acquire(config)?;

    if config.venv_path.exists() && !config.is_installed() {
        on_line("[omni-asr] Removing stale virtual environment...");
        fs::remove_dir_all(&config.venv_path)
            .map_err(|e| format!("Failed to remove stale omni-asr environment: {e}"))?;
    }

    if config.use_wsl {
        install_runtime_wsl(config, on_line)?;
        fs::write(config.wsl_install_stamp_path(), config.install_stamp_contents())
            .map_err(|e| e.to_string())?;
    } else {
        install_runtime_native(config, on_line)?;
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
            .arg("-m").arg("pip").arg("install").arg("--upgrade").arg("pip"),
        "upgrade pip for omni-asr",
        on_line.clone(),
    )?;
    install_native_runtime_packages(&python_path, config.install_variant(), on_line.clone())?;
    run_command(
        Command::new(&python_path)
            .arg("-m").arg("pip").arg("install").arg("-r").arg(&config.requirements_path),
        "install omni-asr runtime dependencies",
        on_line,
    )?;

    Ok(())
}

fn install_runtime_wsl<F>(config: &OmniAsrConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    let venv_wsl = to_wsl_path(&config.venv_path);
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
        ).into());
    }
    on_line("[omni-asr] python3-venv is available.");

    // 1. Create venv inside WSL
    let create_venv_script = format!(
        "python3 -m venv {venv_wsl} 2>&1 && echo 'venv created'"
    );
    run_wsl_command(&create_venv_script, "create omni-asr WSL virtual environment", on_line.clone())?;

    // 2. Upgrade pip
    let upgrade_pip_script = format!(
        "{venv_wsl}/bin/python3 -m pip install --upgrade pip"
    );
    run_wsl_command(&upgrade_pip_script, "upgrade pip for omni-asr (WSL)", on_line.clone())?;

    // 3. Install the torch/fairseq2 pair that matches the requested runtime.
    install_wsl_runtime_packages(&venv_wsl, install_variant, on_line.clone())?;

    // 4. Install requirements
    let install_req_script = format!(
        "{venv_wsl}/bin/python3 -m pip install -r {req_wsl}"
    );
    run_wsl_command(&install_req_script, "install omni-asr dependencies (WSL)", on_line)?;

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
        return Err("omni-asr setup is still running.".into());
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
        let venv_wsl = to_wsl_path(&config.venv_path);
        let script_wsl = to_wsl_path(&config.worker_script_path);
        // Pass the Windows-translated models dir into WSL as an env var the worker can use.
        let models_wsl = to_wsl_path(&config.models_dir);

        Command::new("wsl")
            .arg("bash")
            .arg("-c")
            .arg(format!(
                "HF_HUB_DISABLE_PROGRESS_BARS=0 TQDM_FORCE=1 OMNI_ASR_MODELS_DIR={models_wsl} {venv_wsl}/bin/python3 -u {script_wsl}"
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

    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        let response = self.send_request(json!({
            "command": "transcribe",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
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
                            if !line_buf.is_empty() {
                                log::warn!("[omni-asr] {}", line_buf);
                                on_line(&line_buf);
                                if let Ok(mut tail_buf) = tail.lock() {
                                    if !tail_buf.is_empty() {
                                        tail_buf.push('\n');
                                    }
                                    tail_buf.push_str(&line_buf);
                                    if tail_buf.len() > 4000 {
                                        let start = tail_buf.len().saturating_sub(4000);
                                        *tail_buf = tail_buf[start..].to_string();
                                    }
                                }
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
