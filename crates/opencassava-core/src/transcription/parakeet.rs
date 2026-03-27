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
    /// BCP-47 language code (e.g. "es", "fr") or empty for auto-detect.
    pub language: String,
    /// Controls whether TitaNet speaker embedding model is downloaded and used.
    pub diarization_enabled: bool,
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

pub fn install_runtime<F>(config: &ParakeetConfig, on_line: F) -> Result<(), String>
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
            "create parakeet virtual environment",
            on_line.clone(),
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
        on_line.clone(),
    )?;

    run_command(
        Command::new(&python_path)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .arg("-r")
            .arg(&config.requirements_path),
        "install parakeet runtime dependencies",
        on_line,
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

pub fn ensure_model<F>(config: &ParakeetConfig, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + 'static,
{
    if !config.is_installed() {
        install_runtime(config, |_| {})?;
    }
    let mut worker = ParakeetWorker::spawn_with_log(config, on_line)?;
    worker.ensure_model(config.diarization_enabled)?;
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
        Self::spawn_with_log(config, |_| {})
    }

    pub fn spawn_with_log<F>(config: &ParakeetConfig, on_line: F) -> Result<Self, String>
    where
        F: Fn(&str) + Send + 'static,
    {
        config.ensure_files()?;
        if !config.is_installed() {
            return Err("parakeet runtime is not installed.".into());
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
        pump_stderr(stderr, Arc::clone(&stderr_tail), on_line);

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

    pub fn ensure_model(&mut self, diarization_enabled: bool) -> Result<(), String> {
        self.send_request(json!({
            "command": "ensure_model",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
            "diarization_enabled": diarization_enabled,
        }))?;
        Ok(())
    }

    pub fn clear_speakers(&mut self) -> Result<(), String> {
        self.send_request(json!({ "command": "clear_speakers" }))?;
        Ok(())
    }

    /// Returns the stable speaker ID for this audio segment, or None if the segment
    /// was too short to embed reliably. Errors if the worker fails.
    pub fn speaker_id(&mut self, samples: &[f32]) -> Result<Option<String>, String> {
        let response = self.send_request(json!({
            "command": "speaker_id",
            "samples": samples,
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
        }))?;
        // Python returns {"speaker_id": "speaker_N"} or {"speaker_id": null}
        Ok(response["speaker_id"].as_str().map(|s| s.to_string()))
    }

    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        let mut payload = json!({
            "command": "transcribe",
            "model": self.config.model.clone(),
            "device": self.config.device.clone(),
            "samples": samples,
        });
        let lang = self.config.language.trim();
        if !lang.is_empty() && lang != "auto" {
            // Strip region suffix: "es-ES" → "es"
            let lang_code = lang.split('-').next().unwrap_or(lang);
            payload["language"] = serde_json::Value::String(lang_code.to_string());
        }
        let response = self.send_request(payload)?;
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

        let json = loop {
            let mut response = String::new();
            self.stdout
                .read_line(&mut response)
                .map_err(|e| format!("Failed to read parakeet worker response: {e}"))?;
            if response.trim().is_empty() {
                let stderr = self.stderr_snapshot();
                let status = self.child.try_wait().ok().flatten();
                return Err(format_worker_exit_error(status, &stderr));
            }
            let trimmed = response.trim();
            if trimmed.starts_with('{') {
                break serde_json::from_str::<serde_json::Value>(trimmed)
                    .map_err(|e| format!("Invalid parakeet worker response: {e}"))?;
            }
            log::warn!("[parakeet][stdout] {trimmed}");
        };
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
                                log::warn!("[parakeet] {}", line_buf);
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

fn run_command<F>(command: &mut Command, description: &str, on_line: F) -> Result<(), String>
where
    F: Fn(&str) + Send + Clone + 'static,
{
    log::info!("[parakeet] Starting {description}");
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
                                log::info!("[parakeet] {}", line_buf);
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
                                log::info!("[parakeet] {}", line_buf);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speaker_id_method_exists() {
        // Compile-time guard: won't compile until speaker_id is added to ParakeetWorker
        // with the correct signature. The test itself is a no-op at runtime.
        let _: fn(&mut ParakeetWorker, &[f32]) -> Result<Option<String>, String> =
            ParakeetWorker::speaker_id;
    }

    #[test]
    fn speaker_id_parses_none_from_result_object() {
        // send_request returns json["result"] already.
        // Python sends {"speaker_id": null} for short segments.
        let result_obj: serde_json::Value = serde_json::from_str(r#"{"speaker_id":null}"#).unwrap();
        let speaker_id: Option<String> = result_obj["speaker_id"].as_str().map(|s| s.to_string());
        assert!(speaker_id.is_none());
    }

    #[test]
    fn speaker_id_parses_some_from_result_object() {
        // Python sends {"speaker_id": "speaker_0"} on a match.
        let result_obj: serde_json::Value =
            serde_json::from_str(r#"{"speaker_id":"speaker_0"}"#).unwrap();
        let speaker_id: Option<String> = result_obj["speaker_id"].as_str().map(|s| s.to_string());
        assert_eq!(speaker_id, Some("speaker_0".to_string()));
    }
}
