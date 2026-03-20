use std::sync::{Arc, Mutex};

/// Orchestrates mic and system audio transcription.
/// Holds runtime state: whether transcription is active and any last error.
/// Platform audio implementations are injected at `start()` time via closures.
pub struct TranscriptionEngine {
    is_running: Arc<Mutex<bool>>,
    last_error: Arc<Mutex<Option<String>>>,
}

impl TranscriptionEngine {
    pub fn new() -> Self {
        Self {
            is_running: Arc::new(Mutex::new(false)),
            last_error: Arc::new(Mutex::new(None)),
        }
    }

    pub fn is_running(&self) -> bool {
        *self.is_running.lock().unwrap()
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().unwrap().clone()
    }

    pub fn validate_model(&self, model_path: &str) -> Result<(), String> {
        if std::path::Path::new(model_path).exists() {
            Ok(())
        } else {
            Err(format!("Model not found: {}", model_path))
        }
    }

    pub fn set_running(&self, running: bool) {
        *self.is_running.lock().unwrap() = running;
    }

    pub fn set_error(&self, error: Option<String>) {
        *self.last_error.lock().unwrap() = error;
    }
}

impl Default for TranscriptionEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_starts_not_running() {
        let engine = TranscriptionEngine::new();
        assert!(!engine.is_running());
    }

    #[test]
    fn engine_reports_error_with_missing_model() {
        let engine = TranscriptionEngine::new();
        let result = engine.validate_model("/nonexistent/path.bin");
        assert!(result.is_err());
    }
}
