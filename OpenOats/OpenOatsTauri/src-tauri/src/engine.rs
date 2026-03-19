// Platform-specific system audio capture.
// On macOS: ScreenCaptureKit-based loopback.
// On Windows: WASAPI loopback.
// Other: no-op stub (from audio_windows non-Windows branch).
#[cfg(target_os = "macos")]
use crate::audio_macos::MacosAudioCapture as SystemAudioCapture;
#[cfg(not(target_os = "macos"))]
use crate::audio_windows::SystemAudioCapture;
use openoats_core::{
    audio::{cpal_mic::CpalMicCapture, AudioCaptureService, MicCaptureService},
    download,
    intelligence::{embedding_client, knowledge_base::KnowledgeBase, notes_engine, suggestion_engine::SuggestionEngine},
    keychain,
    models::{MeetingTemplate, SessionRecord, Speaker},
    settings::AppSettings,
    storage::{session_store::SessionStore, transcript_logger::TranscriptLogger},
    transcription::streaming_transcriber::StreamingTranscriber,
};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::Mutex as AsyncMutex;
use tauri::{AppHandle, Emitter, Manager};

// ── Payloads ────────────────────────────────────────────────────────────────

#[derive(Clone, Serialize)]
pub struct TranscriptPayload {
    pub text: String,
    pub speaker: String,
}

#[derive(Clone, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiKeysPayload {
    pub open_router_api_key: String,
    pub voyage_api_key: String,
    pub open_ai_llm_api_key: String,
    pub open_ai_embed_api_key: String,
}

// ── AppState ────────────────────────────────────────────────────────────────

pub struct AppState {
    pub settings: Mutex<AppSettings>,
    pub session_store: Mutex<SessionStore>,
    pub transcript_logger: Mutex<TranscriptLogger>,
    pub knowledge_base: AsyncMutex<KnowledgeBase>,
    pub suggestion_engine: Mutex<SuggestionEngine>,
    pub audio_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    pub is_running: Mutex<bool>,
}

impl AppState {
    pub fn new() -> Self {
        let settings = AppSettings::load();
        // Derive KB cache path from the settings path (same OpenOats data dir)
        let kb_cache = AppSettings::default_path()
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .join("kb_cache.json");
        let kb_fingerprint = format!("{}:{}", settings.embedding_provider, settings.ollama_embed_model);
        Self {
            knowledge_base: AsyncMutex::new(KnowledgeBase::new(kb_cache, kb_fingerprint)),
            suggestion_engine: Mutex::new(SuggestionEngine::new()),
            session_store: Mutex::new(SessionStore::with_default_path()),
            transcript_logger: Mutex::new(TranscriptLogger::with_default_path()),
            settings: Mutex::new(settings),
            audio_task: Mutex::new(None),
            is_running: Mutex::new(false),
        }
    }

    pub fn model_path(app: &AppHandle) -> Result<PathBuf, String> {
        app.path()
            .app_data_dir()
            .map(|p| p.join("ggml-base.en.bin"))
            .map_err(|e| e.to_string())
    }
}

// ── LLM / Embed resolver helpers ─────────────────────────────────────────────

fn llm_base_url_and_key(settings: &AppSettings) -> (String, Option<String>) {
    match settings.llm_provider.as_str() {
        "ollama" => (
            format!("{}/v1", settings.ollama_base_url.trim_end_matches('/')),
            None,
        ),
        "openai" => (
            normalize_openai_base_url(&settings.open_ai_llm_base_url),
            keychain::KeyEntry::open_ai_llm_api_key().load(),
        ),
        _ => {
            let key = keychain::KeyEntry::open_router_api_key().load();
            ("https://openrouter.ai/api/v1".into(), key)
        }
    }
}

fn embed_config(settings: &AppSettings) -> (String, Option<String>, String) {
    match settings.embedding_provider.as_str() {
        "ollama" => (
            format!("{}/v1", settings.ollama_base_url.trim_end_matches('/')),
            None,
            settings.ollama_embed_model.clone(),
        ),
        "openai" => {
            let key = keychain::KeyEntry::open_ai_embed_api_key().load();
            (
                normalize_openai_base_url(&settings.open_ai_embed_base_url),
                key,
                settings.open_ai_embed_model.clone(),
            )
        }
        _ => {
            let key = keychain::KeyEntry::voyage_api_key().load();
            ("https://api.voyageai.com/v1".into(), key, "voyage-3-lite".into())
        }
    }
}

fn normalize_openai_base_url(base_url: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    if trimmed.ends_with("/v1") {
        trimmed.into()
    } else {
        format!("{trimmed}/v1")
    }
}

// ── Tauri commands ───────────────────────────────────────────────────────────

#[tauri::command]
pub fn check_model(app: AppHandle) -> Result<bool, String> {
    let path = AppState::model_path(&app)?;
    Ok(download::model_exists(&path))
}

#[tauri::command]
pub fn get_model_path(app: AppHandle) -> Result<String, String> {
    AppState::model_path(&app).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn get_settings(state: tauri::State<'_, Arc<AppState>>) -> AppSettings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_api_keys() -> ApiKeysPayload {
    ApiKeysPayload {
        open_router_api_key: keychain::KeyEntry::open_router_api_key().load().unwrap_or_default(),
        voyage_api_key: keychain::KeyEntry::voyage_api_key().load().unwrap_or_default(),
        open_ai_llm_api_key: keychain::KeyEntry::open_ai_llm_api_key().load().unwrap_or_default(),
        open_ai_embed_api_key: keychain::KeyEntry::open_ai_embed_api_key().load().unwrap_or_default(),
    }
}

#[tauri::command]
pub fn save_api_keys(new_keys: ApiKeysPayload) -> Result<(), String> {
    keychain::KeyEntry::open_router_api_key()
        .save(&new_keys.open_router_api_key)
        .map_err(|e| e.to_string())?;
    keychain::KeyEntry::voyage_api_key()
        .save(&new_keys.voyage_api_key)
        .map_err(|e| e.to_string())?;
    keychain::KeyEntry::open_ai_llm_api_key()
        .save(&new_keys.open_ai_llm_api_key)
        .map_err(|e| e.to_string())?;
    keychain::KeyEntry::open_ai_embed_api_key()
        .save(&new_keys.open_ai_embed_api_key)
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn save_settings(
    new_settings: AppSettings,
    state: tauri::State<'_, Arc<AppState>>,
) {
    let mut s = state.settings.lock().unwrap();
    *s = new_settings;
    s.save();
}

#[tauri::command]
pub fn list_mic_devices() -> Vec<String> {
    CpalMicCapture::available_device_names()
}

#[tauri::command]
pub fn start_transcription(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<String, String> {
    let model_path = AppState::model_path(&app)?;
    if !download::model_exists(&model_path) {
        return Err("Whisper model not found. Download it first.".into());
    }

    let mut running = state.is_running.lock().unwrap();
    if *running {
        let session_id = state.session_store.lock().unwrap()
            .current_session_id()
            .map(str::to_owned)
            .ok_or_else(|| "Transcription is already running, but no active session ID was found.".to_string())?;
        return Ok(session_id);
    }
    *running = true;
    drop(running);

    let session_id = {
        let mut session_store = state.session_store.lock().unwrap();
        session_store.start_session();
        session_store.current_session_id()
            .map(str::to_owned)
            .ok_or_else(|| "Failed to create a recording session.".to_string())?
    };
    state.transcript_logger.lock().unwrap().start_session();
    state.suggestion_engine.lock().unwrap().clear();

    let model_str = model_path.to_string_lossy().into_owned();
    let app_clone = app.clone();
    let state_clone = Arc::clone(&state);

    let settings = state.settings.lock().unwrap().clone();
    let device_name = settings.input_device_name.clone();
    let language = settings.transcription_locale
        .split('-').next().unwrap_or("en").to_string();

    let handle = tauri::async_runtime::spawn(async move {
        // ── "Them" system audio (WASAPI loopback) ──────────────────────────
        let them_app = app_clone.clone();
        let them_state = Arc::clone(&state_clone);
        let them_model = model_str.clone();
        let them_lang = language.clone();

        tauri::async_runtime::spawn(async move {
            let sys = SystemAudioCapture::new();
            let them_stream = match sys.buffer_stream().await {
                Ok(s) => s,
                Err(e) => {
                    log::warn!("System audio capture unavailable: {e}");
                    return;
                }
            };
            let app_t = them_app.clone();
            let state_t = Arc::clone(&them_state);
            let on_them = move |text: String| {
                let payload = TranscriptPayload { text: text.clone(), speaker: "them".into() };
                app_t.emit("transcript", &payload).ok();
                let record = SessionRecord {
                    speaker: Speaker::Them,
                    text: text.clone(),
                    timestamp: chrono::Utc::now(),
                    suggestions: None, kb_hits: None,
                    suggestion_decision: None,
                    surfaced_suggestion_text: None,
                    conversation_state_summary: None,
                };
                state_t.session_store.lock().unwrap().append_record(&record).ok();
                state_t.transcript_logger.lock().unwrap().append("Them", &text, chrono::Utc::now());
            };
            let transcriber = StreamingTranscriber::new(them_model, them_lang, Box::new(on_them));
            transcriber.run(them_stream).await;
        });

        // ── "You" mic capture ──────────────────────────────────────────────
        let mic = CpalMicCapture::new();
        let mic_stream = mic.buffer_stream_for_device(device_name.as_deref());
        let app_y = app_clone.clone();
        let state_y = Arc::clone(&state_clone);
        let on_you = move |text: String| {
            let payload = TranscriptPayload { text: text.clone(), speaker: "you".into() };
            app_y.emit("transcript", &payload).ok();
            let record = SessionRecord {
                speaker: Speaker::You,
                text: text.clone(),
                timestamp: chrono::Utc::now(),
                suggestions: None, kb_hits: None,
                suggestion_decision: None,
                surfaced_suggestion_text: None,
                conversation_state_summary: None,
            };
            state_y.session_store.lock().unwrap().append_record(&record).ok();
            state_y.transcript_logger.lock().unwrap().append("You", &text, chrono::Utc::now());
        };

        app_clone.emit("whisper-ready", ()).ok();
        let transcriber = StreamingTranscriber::new(model_str, language, Box::new(on_you));
        transcriber.run(mic_stream).await;
    });

    *state.audio_task.lock().unwrap() = Some(handle);
    Ok(session_id)
}

#[tauri::command]
pub fn stop_transcription(state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    if let Some(handle) = state.audio_task.lock().unwrap().take() {
        handle.abort();
    }
    state.session_store.lock().unwrap().end_session();
    state.transcript_logger.lock().unwrap().end_session();
    *state.is_running.lock().unwrap() = false;
    Ok(())
}

#[tauri::command]
pub async fn download_model(app: AppHandle) -> Result<(), String> {
    let model_path = AppState::model_path(&app)?;
    let app_clone = app.clone();
    download::download_model(model_path, move |pct| {
        app_clone.emit("model-download-progress", pct).ok();
    }).await?;
    app.emit("model-download-done", ()).ok();
    Ok(())
}

#[tauri::command]
pub async fn generate_notes(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    session_id: String,
    template_id: Option<String>,
) -> Result<String, String> {
    let settings = state.settings.lock().unwrap().clone();
    let records = state.session_store.lock().unwrap().load_transcript(&session_id);
    let transcript_chars: usize = records.iter().map(|record| record.text.len()).sum();
    log::info!(
        "generate_notes requested: session_id={}, template_id={:?}, utterances={}, transcript_chars={}",
        session_id,
        template_id,
        records.len(),
        transcript_chars
    );
    if records.is_empty() {
        log::warn!("generate_notes aborted: transcript is empty for session_id={}", session_id);
        return Err(format!("No transcript found for session `{session_id}`."));
    }

    let template = template_id
        .as_deref()
        .and_then(|id| MeetingTemplate::built_ins().into_iter().find(|template| template.id.to_string() == id))
        .unwrap_or_else(|| MeetingTemplate::built_ins().into_iter().next().unwrap());
    let (base_url, api_key) = llm_base_url_and_key(&settings);
    let model = if settings.llm_provider == "ollama" {
        settings.ollama_llm_model.clone()
    } else {
        settings.selected_model.clone()
    };

    let app_c = app.clone();
    let on_chunk = move |chunk: String| { app_c.emit("notes-chunk", chunk).ok(); };

    let result = notes_engine::generate_notes(
        &records,
        &template,
        &base_url,
        api_key.as_deref(),
        &model,
        on_chunk,
    ).await?;

    state.session_store.lock().unwrap().save_notes(
        &session_id,
        openoats_core::models::EnhancedNotes {
            template: (&template).into(),
            generated_at: chrono::Utc::now(),
            markdown: result.clone(),
        },
    );

    app.emit("notes-ready", ()).ok();
    Ok(result)
}

#[tauri::command]
pub async fn index_kb(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<usize, String> {
    let settings = state.settings.lock().unwrap().clone();
    let folder = match &settings.kb_folder_path {
        Some(p) => PathBuf::from(p),
        None => return Err("No KB folder configured".into()),
    };

    let (embed_url, embed_key, embed_model) = embed_config(&settings);
    let embed_fn = {
        let url = embed_url.clone();
        let key = embed_key.clone();
        let model = embed_model.clone();
        move |texts: Vec<String>| {
            let url = url.clone();
            let key = key.clone();
            let model = model.clone();
            async move {
                embedding_client::embed(&url, key.as_deref(), &model, &texts, None, None).await
            }
        }
    };

    let count = {
        let mut kb = state.knowledge_base.lock().await;
        kb.index(&folder, embed_fn).await?
    };

    app.emit("kb-indexed", count).ok();
    Ok(count)
}

#[tauri::command]
pub fn update_kb_folder(
    folder: String,
    state: tauri::State<'_, Arc<AppState>>,
) {
    let mut s = state.settings.lock().unwrap();
    s.kb_folder_path = Some(folder);
    s.save();
}

#[tauri::command]
pub fn suggestion_feedback(suggestion_id: String, helpful: bool) {
    log::info!("suggestion_feedback: id={} helpful={}", suggestion_id, helpful);
    // TODO: persist feedback to session sidecar for fine-tuning / analytics
}

#[tauri::command]
pub fn show_overlay(app: AppHandle) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("overlay") {
        w.show().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn hide_overlay(app: AppHandle) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("overlay") {
        w.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_content_protection(app: AppHandle, enabled: bool) -> Result<(), String> {
    for label in ["main", "overlay"] {
        if let Some(w) = app.get_webview_window(label) {
            w.set_content_protected(enabled).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_state_initializes_without_panic() {
        let state = AppState::new();
        assert!(!*state.is_running.lock().unwrap());
    }
}
