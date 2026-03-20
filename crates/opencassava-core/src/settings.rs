use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(default = "default_model", alias = "selected_model")]
    pub selected_model: String,

    #[serde(default = "default_locale", alias = "transcription_locale")]
    pub transcription_locale: String,

    #[serde(default = "default_transcription_model", alias = "transcription_model")]
    pub transcription_model: String,

    #[serde(default, alias = "input_device_name")]
    pub input_device_name: Option<String>,

    #[serde(default = "default_whisper_model", alias = "whisper_model")]
    pub whisper_model: String,

    #[serde(default, alias = "system_audio_device_name")]
    pub system_audio_device_name: Option<String>,

    #[serde(default = "default_llm_provider", alias = "llm_provider")]
    pub llm_provider: String,

    #[serde(default = "default_embedding_provider", alias = "embedding_provider")]
    pub embedding_provider: String,

    #[serde(default = "default_ollama_url", alias = "ollama_base_url")]
    pub ollama_base_url: String,

    #[serde(default = "default_ollama_llm_model", alias = "ollama_llm_model")]
    pub ollama_llm_model: String,

    #[serde(default = "default_ollama_embed_model", alias = "ollama_embed_model")]
    pub ollama_embed_model: String,

    #[serde(default = "default_openai_llm_url", alias = "open_ai_llm_base_url")]
    pub open_ai_llm_base_url: String,

    #[serde(default = "default_openai_embed_url", alias = "open_ai_embed_base_url")]
    pub open_ai_embed_base_url: String,

    #[serde(default = "default_openai_embed_model", alias = "open_ai_embed_model")]
    pub open_ai_embed_model: String,

    #[serde(
        default = "default_suggestion_interval_seconds",
        alias = "suggestion_interval_seconds"
    )]
    pub suggestion_interval_seconds: u64,

    #[serde(default, alias = "kb_folder_path")]
    pub kb_folder_path: Option<String>,

    #[serde(default = "default_notes_folder", alias = "notes_folder_path")]
    pub notes_folder_path: String,

    #[serde(default, alias = "has_acknowledged_recording_consent")]
    pub has_acknowledged_recording_consent: bool,

    #[serde(default = "default_true", alias = "hide_from_screen_share")]
    pub hide_from_screen_share: bool,

    #[serde(default, alias = "has_completed_onboarding")]
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
            .join("OpenCassava")
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
            whisper_model: default_whisper_model(),
            system_audio_device_name: None,
            llm_provider: default_llm_provider(),
            embedding_provider: default_embedding_provider(),
            ollama_base_url: default_ollama_url(),
            ollama_llm_model: default_ollama_llm_model(),
            ollama_embed_model: default_ollama_embed_model(),
            open_ai_llm_base_url: default_openai_llm_url(),
            open_ai_embed_base_url: default_openai_embed_url(),
            open_ai_embed_model: default_openai_embed_model(),
            suggestion_interval_seconds: default_suggestion_interval_seconds(),
            kb_folder_path: None,
            notes_folder_path: default_notes_folder(),
            has_acknowledged_recording_consent: false,
            hide_from_screen_share: true,
            has_completed_onboarding: false,
        }
    }
}

fn default_whisper_model() -> String {
    "auto".into()
}
fn default_model() -> String {
    "google/gemini-3-flash-preview".into()
}
fn default_locale() -> String {
    "en-US".into()
}
fn default_transcription_model() -> String {
    "whisper-base".into()
}
fn default_llm_provider() -> String {
    "openrouter".into()
}
fn default_embedding_provider() -> String {
    "voyage".into()
}
fn default_ollama_url() -> String {
    "http://localhost:11434".into()
}
fn default_ollama_llm_model() -> String {
    "qwen3:8b".into()
}
fn default_ollama_embed_model() -> String {
    "nomic-embed-text".into()
}
fn default_openai_llm_url() -> String {
    "http://localhost:1234".into()
}
fn default_openai_embed_url() -> String {
    "http://localhost:8080".into()
}
fn default_openai_embed_model() -> String {
    "text-embedding-3-small".into()
}
fn default_suggestion_interval_seconds() -> u64 {
    30
}
fn default_true() -> bool {
    true
}
fn default_notes_folder() -> String {
    dirs::document_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("OpenCassava")
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

    #[test]
    fn whisper_model_defaults_to_base_en() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert_eq!(s.whisper_model, "auto");
    }

    #[test]
    fn system_audio_device_name_defaults_to_none() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert!(s.system_audio_device_name.is_none());
    }

    #[test]
    fn whisper_model_missing_from_json_uses_default() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        // Write a settings file that doesn't contain whisper_model
        std::fs::write(&path, r#"{"selectedModel":"test"}"#).unwrap();
        let s = AppSettings::load_from(path);
        assert_eq!(s.whisper_model, "auto");
    }

    #[test]
    fn whisper_model_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.whisper_model = "base".into();
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(s2.whisper_model, "base");
    }

    #[test]
    fn system_audio_device_name_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.system_audio_device_name = Some("Speakers (Realtek)".into());
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(
            s2.system_audio_device_name.as_deref(),
            Some("Speakers (Realtek)")
        );
    }

    #[test]
    fn suggestion_interval_defaults_and_persists() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        assert_eq!(s.suggestion_interval_seconds, 30);
        s.suggestion_interval_seconds = 180;
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(s2.suggestion_interval_seconds, 180);
    }
}
