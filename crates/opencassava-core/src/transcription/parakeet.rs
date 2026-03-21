use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

const WORKER_SCRIPT: &str = include_str!("parakeet_worker.py");
const REQUIREMENTS: &str = include_str!("parakeet_requirements.txt");

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ParakeetConfig {
    pub runtime_root: PathBuf,
    pub worker_script_path: PathBuf,
    pub requirements_path: PathBuf,
    pub venv_path: PathBuf,
    pub models_dir: PathBuf,
    pub model: String,
    pub device: String,
}

impl ParakeetConfig {
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
        let device = self.device.replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        let model = self.model.replace(|c: char| !c.is_ascii_alphanumeric(), "_");
        self.runtime_root
            .join(format!("model-{model}-{device}.stamp"))
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

pub fn install_runtime(config: &ParakeetConfig) -> Result<(), String> {
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
            "create parakeet virtual environment",
        )?;
    }

    let python_path = config.python_path();
    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("--upgrade")
            .arg("pip"),
        "upgrade pip for parakeet",
    )?;

    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-r")
            .arg(&config.requirements_path),
        "install parakeet runtime dependencies",
    )?;

    fs::write(config.install_stamp_path(), REQUIREMENTS).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn health_check(config: &ParakeetConfig) -> Result<(), String> {
    if config.setup_lock_path().exists() {
        return Err("parakeet setup is still running.".into());
    }
    if !config.is_installed() {
        return Err("parakeet runtime is not installed.".into());
    }
    let mut worker = ParakeetWorker::spawn(config)?;
    worker.health()?;
    let _ = worker.shutdown();
    Ok(())
}

pub fn ensure_model(config: &ParakeetConfig) -> Result<(), String> {
    if !config.is_installed() {
        install_runtime(config)?;
    }
    let mut worker = ParakeetWorker::spawn(config)?;
    worker.ensure_model()?;
    fs::write(config.model_stamp_path(), &config.model).map_err(|e| e.to_string())?;
    let _ = worker.shutdown();
    Ok(())
}

pub struct ParakeetWorker {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    stderr_tail: Arc<Mutex<String>>,
    config: ParakeetConfig,
}

impl ParakeetWorker {
    pub fn spawn(config: &ParakeetConfig) -> Result<Self, String> {
        config.ensure_files()?;
        if !config.is_installed() {
            return Err("parakeet runtime is not installed.".into());
        }

        let mut child = Command::new(config.python_path())
            .arg("-u")
            .arg(&config.worker_script_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to launch parakeet worker: {e}"))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Failed to open stdin for parakeet worker.".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to open stdout for parakeet worker.".to_string())?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| "Failed to open stderr for parakeet worker.".to_string())?;
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
            .map_err(|e| format!("Failed to write to parakeet worker: {e}"))?;

        let mut response = String::new();
        self.stdout
            .read_line(&mut response)
            .map_err(|e| format!("Failed to read parakeet worker response: {e}"))?;
        if response.trim().is_empty() {
            let stderr = self.stderr_snapshot();
            let status = self.child.try_wait().ok().flatten();
            return Err(format_worker_exit_error(status, &stderr));
        }
        let json: serde_json::Value = serde_json::from_str(response.trim())
            .map_err(|e| format!("Invalid parakeet worker response: {e}"))?;
        if json["ok"].as_bool().unwrap_or(false) {
            Ok(json["result"].clone())
        } else {
            Err(json["error"]
                .as_str()
                .unwrap_or("Unknown parakeet worker error.")
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

impl Drop for ParakeetWorker {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

fn pump_stderr(stderr: impl Read + Send + 'static, tail: Arc<Mutex<String>>) {
    thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines().map_while(Result::ok) {
            log::warn!("[parakeet] {line}");
            if let Ok(mut buffer) = tail.lock() {
                if !buffer.is_empty() {
                    buffer.push('\n');
                }
                buffer.push_str(&line);
                if buffer.len() > 4000 {
                    let start = buffer.len().saturating_sub(4000);
                    *buffer = buffer[start..].to_string();
                }
            }
        }
    });
}

fn format_worker_exit_error(status: Option<std::process::ExitStatus>, stderr: &str) -> String {
    let mut message = "parakeet worker exited without a response.".to_string();
    if let Some(status) = status {
        message.push_str(&format!(" Exit status: {status}."));
    }
    if !stderr.is_empty() {
        message.push_str(" Worker stderr: ");
        message.push_str(stderr);
    }
    message
}

fn run_command(command: &mut Command, description: &str) -> Result<(), String> {
    log::info!("[parakeet] Starting {description}");
    let output = command
        .output()
        .map_err(|e| format!("Failed to {description}: {e}"))?;
    if output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if !stderr.trim().is_empty() {
            log::info!("[parakeet] {description} stderr: {}", stderr.trim());
        }
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
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
    fn acquire(config: &ParakeetConfig) -> Result<Self, String> {
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

    Err("Python 3 was not found. Install Python 3 to enable parakeet.".into())
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

pub fn model_storage_exists(config: &ParakeetConfig) -> bool {
    config.model_stamp_path().exists()
}
