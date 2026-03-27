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

    #[serde(default = "default_stt_provider", alias = "stt_provider")]
    pub stt_provider: String,

    #[serde(
        default = "default_faster_whisper_model",
        alias = "faster_whisper_model"
    )]
    pub faster_whisper_model: String,

    #[serde(
        default = "default_faster_whisper_compute_type",
        alias = "faster_whisper_compute_type"
    )]
    pub faster_whisper_compute_type: String,

    #[serde(
        default = "default_faster_whisper_device",
        alias = "faster_whisper_device"
    )]
    pub faster_whisper_device: String,

    #[serde(default = "default_parakeet_model", alias = "parakeet_model")]
    pub parakeet_model: String,

    #[serde(default = "default_parakeet_device", alias = "parakeet_device")]
    pub parakeet_device: String,

    #[serde(default = "default_omni_asr_model", alias = "omni_asr_model")]
    pub omni_asr_model: String,

    #[serde(default = "default_omni_asr_device", alias = "omni_asr_device")]
    pub omni_asr_device: String,

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

    #[serde(default = "default_kb_surfacing_system_prompt")]
    pub kb_surfacing_system_prompt: String,

    #[serde(default = "default_suggestion_synthesis_system_prompt")]
    pub suggestion_synthesis_system_prompt: String,

    #[serde(default = "default_smart_question_system_prompt")]
    pub smart_question_system_prompt: String,

    #[serde(default = "default_true")]
    pub diarization_enabled: bool,

    #[serde(default = "default_true", alias = "echo_cancellation_enabled")]
    pub echo_cancellation_enabled: bool,

    #[serde(default)]
    pub mic_calibration_rms: Option<f32>,

    #[serde(default = "default_mic_threshold_multiplier")]
    pub mic_threshold_multiplier: f32,
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
        let mut s: Self = if let Ok(data) = std::fs::read_to_string(&path) {
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            Self::default()
        };
        // Migrate old HuggingFace-style omni-asr model names to fairseq2 card names.
        s.omni_asr_model = match s.omni_asr_model.as_str() {
            "facebook/omnilingual-asr-300m" | "omnilingual-asr-300m" => "omniASR_CTC_300M",
            "facebook/omnilingual-asr-1b" | "omnilingual-asr-1b" => "omniASR_CTC_1B",
            "facebook/omnilingual-asr-3b" | "omnilingual-asr-3b" => "omniASR_CTC_3B",
            "facebook/omnilingual-asr-7b" | "omnilingual-asr-7b" => "omniASR_LLM_7B",
            other => other,
        }
        .to_string();
        s
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
            stt_provider: default_stt_provider(),
            faster_whisper_model: default_faster_whisper_model(),
            faster_whisper_compute_type: default_faster_whisper_compute_type(),
            faster_whisper_device: default_faster_whisper_device(),
            parakeet_model: default_parakeet_model(),
            parakeet_device: default_parakeet_device(),
            omni_asr_model: default_omni_asr_model(),
            omni_asr_device: default_omni_asr_device(),
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
            kb_surfacing_system_prompt: default_kb_surfacing_system_prompt(),
            suggestion_synthesis_system_prompt: default_suggestion_synthesis_system_prompt(),
            smart_question_system_prompt: default_smart_question_system_prompt(),
            diarization_enabled: default_true(),
            echo_cancellation_enabled: default_true(),
            mic_calibration_rms: None,
            mic_threshold_multiplier: default_mic_threshold_multiplier(),
        }
    }
}

fn default_mic_threshold_multiplier() -> f32 {
    0.6
}

fn default_whisper_model() -> String {
    "auto".into()
}
fn default_stt_provider() -> String {
    "whisper-rs".into()
}
fn default_faster_whisper_model() -> String {
    "base".into()
}
fn default_faster_whisper_compute_type() -> String {
    "default".into()
}
fn default_faster_whisper_device() -> String {
    "auto".into()
}
fn default_parakeet_model() -> String {
    "nvidia/parakeet-tdt-0.6b-v3".into()
}
fn default_parakeet_device() -> String {
    "auto".into()
}
fn default_omni_asr_model() -> String {
    "omniASR_CTC_300M".into()
}
fn default_omni_asr_device() -> String {
    "auto".into()
}
fn default_model() -> String {
    "nvidia/nemotron-3-nano-4b".into()
}
fn default_locale() -> String {
    "auto".into()
}
fn default_transcription_model() -> String {
    "whisper-base".into()
}
fn default_llm_provider() -> String {
    "openai".into()
}
fn default_embedding_provider() -> String {
    "openai".into()
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
    "http://127.0.0.1:1234".into()
}
fn default_openai_embed_url() -> String {
    "http://127.0.0.1:1234".into()
}
fn default_openai_embed_model() -> String {
    "jina-embeddings-v5-text-small-retrieval".into()
}
fn default_suggestion_interval_seconds() -> u64 {
    30
}
fn default_true() -> bool {
    true
}
fn default_kb_surfacing_system_prompt() -> String {
    "You are a real-time meeting intelligence assistant. Decide whether retrieved knowledge base context is relevant enough to surface as a live suggestion RIGHT NOW.\n\nEvaluate on four dimensions:\n- Relevance: Does the KB content directly address the current topic?\n- Helpfulness: Would it give the participant a concrete advantage in this moment?\n- Timing: Is this the right moment — not too early, not after the window has passed?\n- Novelty: Is this meaningfully different from suggestions already surfaced?\n\nBe selective. Only return shouldSurface=true when the content provides clear, immediate value. Interrupting with a weak suggestion is worse than staying silent.\n\nReturn only valid JSON: {\"shouldSurface\": bool, \"confidence\": 0-1, \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \"timingScore\": 0-1, \"noveltyScore\": 0-1, \"reason\": \"one sentence\"}".into()
}
fn default_suggestion_synthesis_system_prompt() -> String {
    "You are a real-time meeting intelligence assistant. Given the current conversation moment and relevant knowledge, write a concise, actionable suggestion the participant can act on immediately.\n\nGuidelines:\n- Lead with the most useful insight or action — skip background context\n- Be specific and concrete, not generic\n- Write as a direct tip to the participant, not a knowledge summary\n- Match the urgency and tone of the conversation\n- 1-2 sentences maximum\n\nReturn only the suggestion text, no labels or extra formatting.".into()
}
fn default_smart_question_system_prompt() -> String {
    "You are a real-time meeting intelligence assistant. Decide whether the participant should ask a clarifying or probing question right now.\n\nSurface a question when you detect:\n- A knowledge gap: key information is missing or assumed\n- An ambiguity: terms or requirements could be interpreted multiple ways\n- An unstated constraint: decisions are being made without surfacing important limits\n- A missing \"why\": proposals lack rationale that would affect the outcome\n\nDo NOT surface a question when:\n- Conversation is flowing and a question would interrupt momentum\n- A similar question was already asked this session\n- The information gap is minor and unlikely to matter\n\nThe question must be specific, natural, and directly probe the missing information. One crisp sentence.\n\nReturn only valid JSON: {\"shouldSurface\": bool, \"question\": \"the question\", \"confidence\": 0-1, \"relevanceScore\": 0-1, \"helpfulnessScore\": 0-1, \"timingScore\": 0-1, \"noveltyScore\": 0-1, \"reason\": \"one sentence\"}".into()
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
        assert_eq!(s.transcription_locale, "auto");
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
    fn stt_provider_defaults_to_whisper_rs() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert_eq!(s.stt_provider, "whisper-rs");
        assert_eq!(s.faster_whisper_model, "base");
        assert_eq!(s.faster_whisper_compute_type, "default");
        assert_eq!(s.faster_whisper_device, "auto");
    }

    #[test]
    fn stt_provider_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.stt_provider = "faster-whisper".into();
        s.faster_whisper_model = "small".into();
        s.faster_whisper_compute_type = "int8".into();
        s.faster_whisper_device = "cpu".into();
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(s2.stt_provider, "faster-whisper");
        assert_eq!(s2.faster_whisper_model, "small");
        assert_eq!(s2.faster_whisper_compute_type, "int8");
        assert_eq!(s2.faster_whisper_device, "cpu");
    }

    #[test]
    fn parakeet_provider_defaults() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert_eq!(s.parakeet_model, "nvidia/parakeet-tdt-0.6b-v3");
        assert_eq!(s.parakeet_device, "auto");
    }

    #[test]
    fn parakeet_provider_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.stt_provider = "parakeet".into();
        s.parakeet_model = "nvidia/parakeet-tdt-0.6b-v3".into();
        s.parakeet_device = "cuda".into();
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert_eq!(s2.stt_provider, "parakeet");
        assert_eq!(s2.parakeet_model, "nvidia/parakeet-tdt-0.6b-v3");
        assert_eq!(s2.parakeet_device, "cuda");
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

    #[test]
    fn diarization_enabled_defaults_to_true() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert!(s.diarization_enabled);
    }

    #[test]
    fn diarization_enabled_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.diarization_enabled = false;
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert!(!s2.diarization_enabled);
    }

    #[test]
    fn echo_cancellation_enabled_defaults_to_true() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert!(s.echo_cancellation_enabled);
    }

    #[test]
    fn echo_cancellation_enabled_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.echo_cancellation_enabled = false;
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert!(!s2.echo_cancellation_enabled);
    }

    #[test]
    fn mic_threshold_defaults() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let s = AppSettings::load_from(path);
        assert!(
            s.mic_calibration_rms.is_none(),
            "mic_calibration_rms should default to None"
        );
        assert!(
            (s.mic_threshold_multiplier - 0.6).abs() < 1e-6,
            "mic_threshold_multiplier should default to 0.6"
        );
    }

    #[test]
    fn mic_threshold_persists_and_reloads() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        let mut s = AppSettings::load_from(path.clone());
        s.mic_calibration_rms = Some(0.042);
        s.mic_threshold_multiplier = 0.7;
        s.save_to(path.clone());
        let s2 = AppSettings::load_from(path);
        assert!((s2.mic_calibration_rms.unwrap() - 0.042).abs() < 1e-6);
        assert!((s2.mic_threshold_multiplier - 0.7).abs() < 1e-6);
    }

    #[test]
    fn mic_threshold_defaults_when_absent_from_json() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, r#"{"selectedModel":"gpt-4o"}"#).unwrap();
        let s = AppSettings::load_from(path);
        assert!(s.mic_calibration_rms.is_none());
        assert!((s.mic_threshold_multiplier - 0.6).abs() < 1e-6);
    }
}
