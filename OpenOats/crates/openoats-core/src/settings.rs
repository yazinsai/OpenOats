use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    #[serde(default = "default_model")]
    pub selected_model: String,

    #[serde(default = "default_locale")]
    pub transcription_locale: String,

    #[serde(default = "default_transcription_model")]
    pub transcription_model: String,

    #[serde(default)]
    pub input_device_name: Option<String>,

    #[serde(default = "default_llm_provider")]
    pub llm_provider: String,

    #[serde(default = "default_embedding_provider")]
    pub embedding_provider: String,

    #[serde(default = "default_ollama_url")]
    pub ollama_base_url: String,

    #[serde(default = "default_ollama_llm_model")]
    pub ollama_llm_model: String,

    #[serde(default = "default_ollama_embed_model")]
    pub ollama_embed_model: String,

    #[serde(default = "default_openai_embed_url")]
    pub open_ai_embed_base_url: String,

    #[serde(default = "default_openai_embed_model")]
    pub open_ai_embed_model: String,

    #[serde(default)]
    pub kb_folder_path: Option<String>,

    #[serde(default = "default_notes_folder")]
    pub notes_folder_path: String,

    #[serde(default)]
    pub has_acknowledged_recording_consent: bool,

    #[serde(default = "default_true")]
    pub hide_from_screen_share: bool,

    #[serde(default)]
    pub has_completed_onboarding: bool,
}

impl AppSettings {
    pub fn load() -> Self {
        Self::load_from(Self::default_path())
    }

    pub fn save(&self) {
        self.save_to(Self::default_path());
    }

    pub fn default_path() -> PathBuf {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("OpenOats")
            .join("settings.json")
    }

    pub fn load_from(path: PathBuf) -> Self {
        if let Ok(data) = std::fs::read_to_string(&path) {
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            Self::default()
        }
    }

    pub fn save_to(&self, path: PathBuf) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }

    pub fn notes_folder_url(&self) -> PathBuf {
        PathBuf::from(&self.notes_folder_path)
    }
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            selected_model: default_model(),
            transcription_locale: default_locale(),
            transcription_model: default_transcription_model(),
            input_device_name: None,
            llm_provider: default_llm_provider(),
            embedding_provider: default_embedding_provider(),
            ollama_base_url: default_ollama_url(),
            ollama_llm_model: default_ollama_llm_model(),
            ollama_embed_model: default_ollama_embed_model(),
            open_ai_embed_base_url: default_openai_embed_url(),
            open_ai_embed_model: default_openai_embed_model(),
            kb_folder_path: None,
            notes_folder_path: default_notes_folder(),
            has_acknowledged_recording_consent: false,
            hide_from_screen_share: true,
            has_completed_onboarding: false,
        }
    }
}

fn default_model() -> String { "google/gemini-3-flash-preview".into() }
fn default_locale() -> String { "en-US".into() }
fn default_transcription_model() -> String { "whisper-base".into() }
fn default_llm_provider() -> String { "openrouter".into() }
fn default_embedding_provider() -> String { "voyage".into() }
fn default_ollama_url() -> String { "http://localhost:11434".into() }
fn default_ollama_llm_model() -> String { "qwen3:8b".into() }
fn default_ollama_embed_model() -> String { "nomic-embed-text".into() }
fn default_openai_embed_url() -> String { "http://localhost:8080".into() }
fn default_openai_embed_model() -> String { "text-embedding-3-small".into() }
fn default_true() -> bool { true }
fn default_notes_folder() -> String {
    dirs::document_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("OpenOats")
        .to_string_lossy()
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn settings_persist_and_reload() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.selected_model = "anthropic/claude-3-haiku".into();
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(s2.selected_model, "anthropic/claude-3-haiku");
    }

    #[test]
    fn settings_defaults_when_no_file() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert_eq!(s.transcription_locale, "en-US");
    }
}
