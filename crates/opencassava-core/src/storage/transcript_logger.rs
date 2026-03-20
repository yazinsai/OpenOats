use chrono::{DateTime, Utc};
use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;

pub struct TranscriptLogger {
    directory: PathBuf,
    current_file: Option<File>,
}

impl TranscriptLogger {
    pub fn new(directory: PathBuf) -> Self {
        let _ = fs::create_dir_all(&directory);
        Self {
            directory,
            current_file: None,
        }
    }

    pub fn with_default_path() -> Self {
        let dir = dirs::document_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("OpenCassava");
        Self::new(dir)
    }

    pub fn start_session(&mut self) {
        let now: DateTime<Utc> = Utc::now();
        let filename = format!("{}.txt", now.format("%Y-%m-%d_%H-%M"));
        let path = self.directory.join(filename);
        match File::create(&path) {
            Ok(mut f) => {
                let header = format!("OpenCassava - {}\n\n", now.format("%B %d, %Y %H:%M"));
                let _ = f.write_all(header.as_bytes());
                self.current_file = Some(f);
            }
            Err(e) => log::error!("TranscriptLogger: failed to create file: {e}"),
        }
    }

    pub fn append(&mut self, speaker: &str, text: &str, timestamp: DateTime<Utc>) {
        let Some(ref mut file) = self.current_file else {
            return;
        };
        let line = format!("[{}] {}: {}\n", timestamp.format("%H:%M:%S"), speaker, text);
        let _ = file.write_all(line.as_bytes());
    }

    pub fn end_session(&mut self) {
        self.current_file = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn creates_txt_file_on_start() {
        let dir = tempdir().unwrap();
        let mut logger = TranscriptLogger::new(dir.path().to_path_buf());
        logger.start_session();
        let files: Vec<_> = std::fs::read_dir(dir.path()).unwrap().collect();
        assert_eq!(files.len(), 1);
        let name = files[0].as_ref().unwrap().file_name();
        assert!(name.to_string_lossy().ends_with(".txt"));
    }

    #[test]
    fn appended_lines_appear_in_file() {
        let dir = tempdir().unwrap();
        let mut logger = TranscriptLogger::new(dir.path().to_path_buf());
        logger.start_session();
        logger.append("You", "hello there", Utc::now());
        logger.end_session();
        let files: Vec<_> = std::fs::read_dir(dir.path()).unwrap().collect();
        let content = std::fs::read_to_string(files[0].as_ref().unwrap().path()).unwrap();
        assert!(content.contains("You: hello there"));
    }
}
