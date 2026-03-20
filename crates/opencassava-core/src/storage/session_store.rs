use crate::models::{
    EnhancedNotes, SessionIndex, SessionRecord, SessionSidecar, SuggestionFeedbackEntry,
};
use chrono::{DateTime, Utc};
use serde_json;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;

pub struct SessionStore {
    sessions_dir: PathBuf,
    current_id: Option<String>,
    current_file: Option<File>,
}

impl SessionStore {
    pub fn new(sessions_dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&sessions_dir);
        Self {
            sessions_dir,
            current_id: None,
            current_file: None,
        }
    }

    pub fn with_default_path() -> Self {
        let dir = dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("OpenCassava")
            .join("sessions");
        Self::new(dir)
    }

    pub fn start_session(&mut self) {
        let now: DateTime<Utc> = Utc::now();
        let id = format!("session_{}", now.format("%Y-%m-%d_%H-%M-%S"));
        let path = self.sessions_dir.join(format!("{}.jsonl", id));
        match File::create(&path) {
            Ok(f) => {
                self.current_id = Some(id);
                self.current_file = Some(f);
            }
            Err(e) => log::error!("SessionStore: failed to create session file: {e}"),
        }
    }

    pub fn current_session_id(&self) -> Option<&str> {
        self.current_id.as_deref()
    }

    pub fn append_record(&mut self, record: &SessionRecord) -> Result<(), String> {
        let file = self.current_file.as_mut().ok_or("no active session")?;
        let mut json = serde_json::to_string(record).map_err(|e| e.to_string())?;
        json.push('\n');
        file.write_all(json.as_bytes()).map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn end_session(&mut self) {
        self.current_file = None;
        self.current_id = None;
    }

    pub fn write_sidecar(&self, sidecar: &SessionSidecar) {
        let path = self
            .sessions_dir
            .join(format!("{}.meta.json", sidecar.index.id));
        match serde_json::to_string_pretty(sidecar) {
            Ok(json) => {
                let _ = fs::write(path, json);
            }
            Err(e) => log::error!("SessionStore: sidecar write failed: {e}"),
        }
    }

    pub fn save_notes(&self, session_id: &str, notes: EnhancedNotes) {
        let mut sidecar = self.read_sidecar_or_stub(session_id);
        sidecar.index.template_snapshot = Some(notes.template.clone());
        sidecar.notes = Some(notes);
        sidecar.index.has_notes = true;
        self.write_sidecar(&sidecar);
    }

    pub fn save_suggestion_feedback(&self, session_id: &str, feedback: SuggestionFeedbackEntry) {
        let mut sidecar = self.read_sidecar_or_stub(session_id);
        sidecar.suggestion_feedback.push(feedback);
        self.write_sidecar(&sidecar);
    }

    fn read_sidecar_or_stub(&self, session_id: &str) -> SessionSidecar {
        if let Some(sidecar) = self.load_sidecar(session_id) {
            return sidecar;
        }
        let started_at = Self::parse_date_from_id(session_id);
        let utterance_count = self.load_transcript(session_id).len();
        SessionSidecar {
            index: SessionIndex {
                id: session_id.to_string(),
                started_at,
                ended_at: None,
                template_snapshot: None,
                title: None,
                utterance_count,
                has_notes: false,
            },
            notes: None,
            suggestion_feedback: Vec::new(),
        }
    }

    pub fn load_sidecar(&self, session_id: &str) -> Option<SessionSidecar> {
        let path = self.sessions_dir.join(format!("{}.meta.json", session_id));
        let data = fs::read_to_string(path).ok()?;
        serde_json::from_str::<SessionSidecar>(&data).ok()
    }

    pub fn load_notes(&self, session_id: &str) -> Option<EnhancedNotes> {
        self.load_sidecar(session_id).and_then(|sidecar| sidecar.notes)
    }

    pub fn load_session_index(&self) -> Vec<SessionIndex> {
        let Ok(entries) = fs::read_dir(&self.sessions_dir) else {
            return vec![];
        };
        let mut map: std::collections::HashMap<String, SessionIndex> =
            std::collections::HashMap::new();

        for entry in entries.flatten() {
            let path = entry.path();
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();

            if name.ends_with(".meta.json") {
                let stem = name.trim_end_matches(".meta.json").to_string();
                if let Ok(data) = fs::read_to_string(&path) {
                    if let Ok(sidecar) = serde_json::from_str::<SessionSidecar>(&data) {
                        map.insert(stem, sidecar.index);
                    }
                }
            }
        }

        for entry in fs::read_dir(&self.sessions_dir)
            .into_iter()
            .flatten()
            .flatten()
        {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                let stem = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                if !map.contains_key(&stem) {
                    let records = self.load_transcript(&stem);
                    map.insert(
                        stem.clone(),
                        SessionIndex {
                            id: stem.clone(),
                            started_at: Self::parse_date_from_id(&stem),
                            ended_at: None,
                            template_snapshot: None,
                            title: None,
                            utterance_count: records.len(),
                            has_notes: false,
                        },
                    );
                }
            }
        }

        let mut sessions: Vec<SessionIndex> = map.into_values().collect();
        sessions.sort_by(|a, b| b.started_at.cmp(&a.started_at));
        sessions
    }

    pub fn load_transcript(&self, session_id: &str) -> Vec<SessionRecord> {
        let path = self.sessions_dir.join(format!("{}.jsonl", session_id));
        let Ok(file) = File::open(&path) else {
            return vec![];
        };
        BufReader::new(file)
            .lines()
            .flatten()
            .filter(|l| !l.is_empty())
            .filter_map(|line| serde_json::from_str::<SessionRecord>(&line).ok())
            .collect()
    }

    fn parse_date_from_id(id: &str) -> DateTime<Utc> {
        let date_part = id.trim_start_matches("session_");
        chrono::NaiveDateTime::parse_from_str(date_part, "%Y-%m-%d_%H-%M-%S")
            .map(|dt| dt.and_utc())
            .unwrap_or_else(|_| Utc::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Speaker;
    use tempfile::tempdir;

    #[test]
    fn start_writes_jsonl_file() {
        let dir = tempdir().unwrap();
        let mut store = SessionStore::new(dir.path().to_path_buf());
        store.start_session();
        assert!(store.current_session_id().is_some());
        let id = store.current_session_id().unwrap().to_string();
        let jsonl = dir.path().join(format!("{}.jsonl", id));
        assert!(jsonl.exists());
    }

    #[test]
    fn append_and_load_roundtrip() {
        let dir = tempdir().unwrap();
        let mut store = SessionStore::new(dir.path().to_path_buf());
        store.start_session();
        let record = SessionRecord {
            speaker: Speaker::You,
            text: "hello".into(),
            timestamp: Utc::now(),
            suggestions: None,
            kb_hits: None,
            suggestion_decision: None,
            surfaced_suggestion_text: None,
            conversation_state_summary: None,
        };
        store.append_record(&record).unwrap();
        store.end_session();

        let sessions = store.load_session_index();
        assert_eq!(sessions.len(), 1);
        let records = store.load_transcript(&sessions[0].id);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].text, "hello");
    }
}
