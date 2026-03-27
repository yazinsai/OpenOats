use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

const WORKER_SCRIPT: &str = include_str!("faster_whisper_worker.py");
const REQUIREMENTS: &str = include_str!("faster_whisper_requirements.txt");

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FasterWhisperConfig {
    pub runtime_root: PathBuf,
    pub worker_script_path: PathBuf,
    pub requirements_path: PathBuf,
    pub venv_path: PathBuf,
    pub models_dir: PathBuf,
    pub model: String,
    pub device: String,
    pub compute_type: String,
}

impl FasterWhisperConfig {
    pub fn python_path(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv_path.join("Scripts").join("python.exe")
        } else {
            self.venv_path.join("bin").join("python3")
        }
    }

    pub fn install_stamp_path(&self) -> PathBuf {
        self.runtime_root.join("install.stamp")
    }

    pub fn model_stamp_path(&self) -> PathBuf {
        let device = self
            .device
            .replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        let compute = self
            .compute_type
            .replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        let model = self
            .model
            .replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        self.runtime_root
            .join(format!("model-{model}-{device}-{compute}.stamp"))
    }

    pub fn setup_lock_path(&self) -> PathBuf {
        self.runtime_root.join("setup.lock")
    }

    pub fn ensure_files(&self) -> Result<(), String> {
        fs::create_dir_all(&self.runtime_root).map_err(|e| e.to_string())?;
        fs::create_dir_all(&self.models_dir).map_err(|e| e.to_string())?;
        fs::write(&self.worker_script_path, WORKER_SCRIPT).map_err(|e| e.to_string())?;
        fs::write(&self.requirements_path, REQUIREMENTS).map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn is_installed(&self) -> bool {
        self.python_path().exists()
            && self.install_stamp_path().exists()
            && fs::read_to_string(self.install_stamp_path())
                .map(|contents| contents == REQUIREMENTS)
                .unwrap_or(false)
    }
}

pub fn install_runtime<F>(config: &FasterWhisperConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    config.ensure_files()?;
    let _lock = SetupLock::acquire(config)?;
    if !config.python_path().exists() {
        let python = detect_system_python()?;
        run_command(
            Command::new(&python.command)
                .args(&python.prefix_args)
                .arg("-m")
                .arg("venv")
                .arg(&config.venv_path),
            "create faster-whisper virtual environment",
            on_line.clone(),
        )?;
    }

    let python_path = config.python_path();
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-v")
            .arg("--upgrade")
            .arg("pip"),
        "upgrade pip for faster-whisper",
        on_line.clone(),
    )?;

    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-v")
            .arg("-r")
            .arg(&config.requirements_path),
        "install faster-whisper runtime dependencies",
        on_line,
    )?;

    fs::write(config.install_stamp_path(), REQUIREMENTS).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn health_check(config: &FasterWhisperConfig) -> Result<(), String> {
    if config.setup_lock_path().exists() {
        return Err("faster-whisper setup is still running.".into());
    }
    if !config.is_installed() {
        return Err("faster-whisper runtime is not installed.".into());
    }
    let mut worker = FasterWhisperWorker::spawn(config)?;
    worker.health()?;
    let _ = worker.shutdown();
    Ok(())
}

pub fn ensure_model<F>(config: &FasterWhisperConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    if !config.is_installed() {
        install_runtime(config, on_line)?;
    }
    let mut worker = FasterWhisperWorker::spawn(config)?;
    worker.ensure_model()?;
    fs::write(config.model_stamp_path(), &config.model).map_err(|e| e.to_string())?;
    let _ = worker.shutdown();
    Ok(())
}

pub struct FasterWhisperWorker {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    stderr_tail: Arc<Mutex<String>>,
    config: FasterWhisperConfig,
}

impl FasterWhisperWorker {
    pub fn spawn(config: &FasterWhisperConfig) -> Result<Self, String> {
        config.ensure_files()?;
        if !config.is_installed() {
            return Err("faster-whisper runtime is not installed.".into());
        }

        let mut child = Command::new(config.python_path())
            .arg("-u")
            .arg(&config.worker_script_path)
            .env("HF_HUB_DISABLE_PROGRESS_BARS", "0")
            .env("TQDM_FORCE", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to launch faster-whisper worker: {e}"))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Failed to open stdin for faster-whisper worker.".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to open stdout for faster-whisper worker.".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Failed to open stderr for faster-whisper worker.".to_string())?;
        let stderr_tail = Arc::new(Mutex::new(String::new()));
        pump_stderr(stderr, Arc::clone(&stderr_tail));

        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            stderr_tail,
            config: config.clone(),
        })
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
            "compute_type": self.config.compute_type.clone(),
            "download_root": self.config.models_dir.clone(),
        }))?;
        Ok(())
    }

    pub fn transcribe(&mut self, samples: &[f32], language: &str) -> Result<String, String> {
        let response = self.send_request(json!({
            "command": "transcribe",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
            "compute_type": self.config.compute_type.clone(),
            "download_root": self.config.models_dir.clone(),
            "language": language,
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
            .map_err(|e| format!("Failed to write to faster-whisper worker: {e}"))?;

        let mut response = String::new();
        self.stdout
            .read_line(&mut response)
            .map_err(|e| format!("Failed to read faster-whisper worker response: {e}"))?;
        if response.trim().is_empty() {
            let stderr = self.stderr_snapshot();
            let status = self.child.try_wait().ok().flatten();
            return Err(format_worker_exit_error(status, &stderr));
        }
        let json: serde_json::Value = serde_json::from_str(response.trim())
            .map_err(|e| format!("Invalid faster-whisper worker response: {e}"))?;
        if json["ok"].as_bool().unwrap_or(false) {
            Ok(json["result"].clone())
        } else {
            Err(json["error"]
                .as_str()
                .unwrap_or("Unknown faster-whisper worker error.")
                .to_string())
        }
    }

    fn stderr_snapshot(&self) -> String {
        self.stderr_tail
            .lock()
            .map(|value| value.trim().to_string())
            .unwrap_or_default()
    }
}

impl Drop for FasterWhisperWorker {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

fn pump_stderr(mut stderr: impl Read + Send + 'static, tail: Arc<Mutex<String>>) {
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
                                log::warn!("[faster-whisper] {}", line_buf);
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
    let mut message = "faster-whisper worker exited without a response.".to_string();
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
    log::info!("[faster-whisper] Starting {description}");
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
                                log::info!("[faster-whisper] {}", line_buf);
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
                                log::info!("[faster-whisper] {}", line_buf);
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
    fn acquire(config: &FasterWhisperConfig) -> Result<Self, String> {
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

fn detect_system_python() -> Result<PythonCandidate, String> {
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

    Err("Python 3 was not found. Install Python 3 to enable faster-whisper.".into())
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

pub fn model_storage_exists(config: &FasterWhisperConfig) -> bool {
    config.model_stamp_path().exists()
}
