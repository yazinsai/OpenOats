// Platform-specific system audio capture.
// On macOS: ScreenCaptureKit-based loopback.
// On Windows: WASAPI loopback.
// Other: no-op stub (from audio_windows non-Windows branch).
#[cfg(target_os = "macos")]
use crate::audio_macos::MacosAudioCapture as SystemAudioCapture;
#[cfg(not(target_os = "macos"))]
use crate::audio_windows::SystemAudioCapture;
use opencassava_core::{
    audio::{cpal_mic::CpalMicCapture, AudioCaptureService, MicCaptureService},
    download,
    intelligence::{
        embedding_client, knowledge_base::KnowledgeBase, notes_engine,
        suggestion_engine::SuggestionEngine,
    },
    keychain,
    models::{EnhancedNotes, MeetingTemplate, SessionRecord, Speaker, SuggestionFeedbackEntry},
    settings::AppSettings,
    storage::{
        session_store::SessionStore, template_store::TemplateStore,
        transcript_logger::TranscriptLogger,
    },
    transcription::streaming_transcriber::StreamingTranscriber,
};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_dialog::DialogExt;
use tokio::sync::Mutex as AsyncMutex;

const SUGGESTION_CONTEXT_WINDOW_SECS: i64 = 180;
const OVERLAY_LABEL: &str = "overlay";
const OVERLAY_SUGGESTION_EVENT: &str = "overlay-suggestion";

fn ensure_overlay_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    if let Some(window) = app.get_webview_window(OVERLAY_LABEL) {
        return Ok(window);
    }

    let window = WebviewWindowBuilder::new(app, OVERLAY_LABEL, WebviewUrl::default())
        .title("OpenCassava Overlay")
        .inner_size(380.0, 160.0)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .visible(false)
        .skip_taskbar(true)
        .build()
        .map_err(|e| e.to_string())?;

    Ok(window)
}

fn emit_overlay_suggestion(window: WebviewWindow, payload: SuggestionPayload) {
    tauri::async_runtime::spawn(async move {
        for delay_ms in [0_u64, 150, 500] {
            if delay_ms > 0 {
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
            }
            let _ = window.emit(OVERLAY_SUGGESTION_EVENT, &payload);
        }
    });
}

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

#[derive(Clone, Serialize)]
pub struct AudioLevelPayload {
    pub you: f32,
    pub them: f32,
}

#[derive(Clone, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestionPayload {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub kb_hits: Vec<opencassava_core::models::KBResult>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestionCheckPayload {
    pub checked_at: String,
    pub surfaced: bool,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDetailsPayload {
    pub transcript: Vec<SessionRecord>,
    pub notes: Option<EnhancedNotes>,
}

// ── AppState ────────────────────────────────────────────────────────────────

pub struct AppState {
    pub settings: Mutex<AppSettings>,
    pub session_store: Mutex<SessionStore>,
    pub template_store: Mutex<TemplateStore>,
    pub transcript_logger: Mutex<TranscriptLogger>,
    pub knowledge_base: AsyncMutex<KnowledgeBase>,
    pub suggestion_engine: AsyncMutex<SuggestionEngine>,
    pub audio_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    pub system_audio_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    pub suggestion_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    pub poll_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
    pub overlay_suggestion: Mutex<Option<SuggestionPayload>>,
    pub is_running: Mutex<bool>,
    pub mic_level: Arc<AtomicU32>,
    pub sys_level: Arc<AtomicU32>,
}

impl AppState {
    fn persistent_data_dir() -> PathBuf {
        AppSettings::default_path()
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .to_path_buf()
    }

    pub fn new() -> Self {
        let settings = AppSettings::load();
        // Derive KB cache path from the stable OpenCassava data dir.
        let kb_cache = Self::persistent_data_dir().join("kb_cache.json");
        let kb_fingerprint = format!(
            "{}:{}",
            settings.embedding_provider, settings.ollama_embed_model
        );
        Self {
            knowledge_base: AsyncMutex::new(KnowledgeBase::new(kb_cache, kb_fingerprint)),
            suggestion_engine: AsyncMutex::new(SuggestionEngine::new()),
            session_store: Mutex::new(SessionStore::with_default_path()),
            template_store: Mutex::new(TemplateStore::load()),
            transcript_logger: Mutex::new(TranscriptLogger::with_default_path()),
            settings: Mutex::new(settings),
            audio_task: Mutex::new(None),
            system_audio_task: Mutex::new(None),
            suggestion_task: Mutex::new(None),
            poll_task: Mutex::new(None),
            overlay_suggestion: Mutex::new(None),
            is_running: Mutex::new(false),
            mic_level: Arc::new(AtomicU32::new(0)),
            sys_level: Arc::new(AtomicU32::new(0)),
        }
    }

    pub fn model_path_for(_app: &AppHandle, model: &str) -> Result<PathBuf, String> {
        Ok(Self::persistent_data_dir().join(opencassava_core::download::model_filename(model)))
    }
}

fn resolve_whisper_model(settings: &AppSettings) -> &'static str {
    let locale = settings.transcription_locale.trim().to_ascii_lowercase();
    let is_english = locale.is_empty() || locale.starts_with("en");

    match settings.whisper_model.as_str() {
        "tiny" => {
            if is_english {
                "tiny-en"
            } else {
                "tiny"
            }
        }
        "tiny-en" => "tiny-en",
        "base" => {
            if is_english {
                "base-en"
            } else {
                "base"
            }
        }
        "base-en" => "base-en",
        "small" => {
            if is_english {
                "small-en"
            } else {
                "small"
            }
        }
        "small-en" => "small-en",
        "auto" => {
            if is_english {
                "base-en"
            } else {
                "base"
            }
        }
        _ => {
            if is_english {
                "base-en"
            } else {
                "base"
            }
        }
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
            (
                "https://api.voyageai.com/v1".into(),
                key,
                "voyage-3-lite".into(),
            )
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

fn compute_rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let mean_sq = samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32;
    mean_sq.sqrt().min(1.0)
}

fn push_recent_utterance(
    buffer: &Arc<Mutex<Vec<opencassava_core::models::Utterance>>>,
    utterance: opencassava_core::models::Utterance,
) {
    let cutoff = chrono::Utc::now() - chrono::Duration::seconds(SUGGESTION_CONTEXT_WINDOW_SECS);
    let mut entries = buffer.lock().unwrap();
    entries.push(utterance);
    entries.retain(|entry| entry.timestamp >= cutoff);
}

// ── Tauri commands ───────────────────────────────────────────────────────────

#[tauri::command]
pub fn check_model(app: AppHandle, model: String) -> Result<bool, String> {
    let path = AppState::model_path_for(&app, &model)?;
    Ok(download::model_exists(&path))
}

#[tauri::command]
pub fn get_model_path(app: AppHandle, model: String) -> Result<String, String> {
    AppState::model_path_for(&app, &model).map(|p| p.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn get_settings(state: tauri::State<'_, Arc<AppState>>) -> AppSettings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_api_keys() -> ApiKeysPayload {
    ApiKeysPayload {
        open_router_api_key: keychain::KeyEntry::open_router_api_key()
            .load()
            .unwrap_or_default(),
        voyage_api_key: keychain::KeyEntry::voyage_api_key()
            .load()
            .unwrap_or_default(),
        open_ai_llm_api_key: keychain::KeyEntry::open_ai_llm_api_key()
            .load()
            .unwrap_or_default(),
        open_ai_embed_api_key: keychain::KeyEntry::open_ai_embed_api_key()
            .load()
            .unwrap_or_default(),
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
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String> {
    let mut s = state.settings.lock().unwrap();
    *s = new_settings;
    s.save();
    let hide_from_screen_share = s.hide_from_screen_share;
    drop(s);
    set_content_protection(app, hide_from_screen_share)?;
    Ok(())
}

#[tauri::command]
pub fn list_mic_devices() -> Vec<String> {
    CpalMicCapture::available_device_names()
}

#[tauri::command]
pub fn list_sys_audio_devices() -> Vec<String> {
    crate::audio_windows::list_render_devices()
}

#[tauri::command]
pub fn start_transcription(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<String, String> {
    let settings = state.settings.lock().unwrap().clone();
    let whisper_model = resolve_whisper_model(&settings);
    let model_path = AppState::model_path_for(&app, whisper_model)?;
    if !download::model_exists(&model_path) {
        return Err("Whisper model not found. Download it first.".into());
    }

    let mut running = state.is_running.lock().unwrap();
    if *running {
        let session_id = state
            .session_store
            .lock()
            .unwrap()
            .current_session_id()
            .map(str::to_owned)
            .ok_or_else(|| {
                "Transcription is already running, but no active session ID was found.".to_string()
            })?;
        return Ok(session_id);
    }
    *running = true;
    drop(running);

    let session_id = {
        let mut session_store = state.session_store.lock().unwrap();
        session_store.start_session();
        session_store
            .current_session_id()
            .map(str::to_owned)
            .ok_or_else(|| "Failed to create a recording session.".to_string())?
    };
    state.transcript_logger.lock().unwrap().start_session();
    state.suggestion_engine.blocking_lock().clear();
    *state.overlay_suggestion.lock().unwrap() = None;
    if let Some(overlay) = app.get_webview_window(OVERLAY_LABEL) {
        let _ = overlay.hide();
    }

    let model_str = model_path.to_string_lossy().into_owned();
    let app_clone = app.clone();
    let state_clone = Arc::clone(&state);

    let device_name = settings.input_device_name.clone();
    let sys_device_name = settings.system_audio_device_name.clone();
    let language = settings
        .transcription_locale
        .split('-')
        .next()
        .unwrap_or("en")
        .to_string();
    let suggestion_interval_secs = settings.suggestion_interval_seconds.max(30);

    let recent_utterances: Arc<Mutex<Vec<opencassava_core::models::Utterance>>> =
        Arc::new(Mutex::new(Vec::new()));

    let handle = tauri::async_runtime::spawn(async move {
        // Audio level polling task — runs until is_running goes false
        let app_lvl = app_clone.clone();
        let ml = Arc::clone(&state_clone.mic_level);
        let sl = Arc::clone(&state_clone.sys_level);
        let running_flag = Arc::clone(&state_clone);
        let poll_handle = tauri::async_runtime::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_millis(100));
            loop {
                interval.tick().await;
                if !*running_flag.is_running.lock().unwrap() {
                    break;
                }
                let you = f32::from_bits(ml.load(Ordering::Relaxed));
                let them = f32::from_bits(sl.load(Ordering::Relaxed));
                app_lvl
                    .emit("audio-level", &AudioLevelPayload { you, them })
                    .ok();
            }
        });
        *state_clone.poll_task.lock().unwrap() = Some(poll_handle);

        // ── "Them" system audio (WASAPI loopback) ──────────────────────────
        let them_app = app_clone.clone();
        let them_state = Arc::clone(&state_clone);
        let them_model = model_str.clone();
        let them_lang = language.clone();
        let recent_utterances_spawn = Arc::clone(&recent_utterances);

        let them_handle = tauri::async_runtime::spawn(async move {
            let sys = SystemAudioCapture::new(sys_device_name.as_deref());
            let them_stream = match sys.buffer_stream().await {
                Ok(s) => s,
                Err(e) => {
                    log::warn!("System audio capture unavailable: {e}");
                    return;
                }
            };
            use futures::StreamExt;
            let sys_level_w = Arc::clone(&them_state.sys_level);
            let them_stream_leveled = them_stream.map(move |chunk: Vec<f32>| {
                let rms = compute_rms(&chunk);
                sys_level_w.store(rms.to_bits(), Ordering::Relaxed);
                chunk
            });

            let recent_utterances_clone = Arc::clone(&recent_utterances_spawn);
            let app_sg = them_app.clone();
            let state_sg = Arc::clone(&them_state);

            let on_them = move |text: String| {
                if !*state_sg.is_running.lock().unwrap() {
                    return;
                }
                use opencassava_core::models::{Speaker, Utterance};
                let utterance = Utterance {
                    id: uuid::Uuid::new_v4(),
                    text: text.clone(),
                    speaker: Speaker::Them,
                    timestamp: chrono::Utc::now(),
                };

                // Emit finalized transcript
                let payload = TranscriptPayload {
                    text: text.clone(),
                    speaker: "them".into(),
                };
                app_sg.emit("transcript", &payload).ok();

                // Append to session store and logger
                let record = SessionRecord {
                    speaker: Speaker::Them,
                    text: text.clone(),
                    timestamp: chrono::Utc::now(),
                    suggestions: None,
                    kb_hits: None,
                    suggestion_decision: None,
                    surfaced_suggestion_text: None,
                    conversation_state_summary: None,
                };
                state_sg
                    .session_store
                    .lock()
                    .unwrap()
                    .append_record(&record)
                    .ok();
                state_sg.transcript_logger.lock().unwrap().append(
                    "Them",
                    &text,
                    chrono::Utc::now(),
                );

                push_recent_utterance(&recent_utterances_clone, utterance.clone());
            };
            let app_vol_t = them_app.clone();
            let state_vol_t = Arc::clone(&them_state);
            let on_them_vol = move |_text: String| {
                if !*state_vol_t.is_running.lock().unwrap() {
                    return;
                }
                app_vol_t
                    .emit(
                        "transcript-volatile",
                        &TranscriptPayload {
                            text: "...".into(),
                            speaker: "them".into(),
                        },
                    )
                    .ok();
            };
            let transcriber = StreamingTranscriber::new(them_model, them_lang, Box::new(on_them))
                .with_volatile(Box::new(on_them_vol));
            transcriber.run(them_stream_leveled).await;
        });
        *state_clone.system_audio_task.lock().unwrap() = Some(them_handle);

        let suggestion_app = app_clone.clone();
        let suggestion_state = Arc::clone(&state_clone);
        let suggestion_recent_utterances = Arc::clone(&recent_utterances);
        let suggestion_handle = tauri::async_runtime::spawn(async move {
            let mut interval =
                tokio::time::interval(std::time::Duration::from_secs(suggestion_interval_secs));
            let mut last_checked_utterance_id: Option<uuid::Uuid> = None;
            interval.tick().await;

            loop {
                interval.tick().await;
                if !*suggestion_state.is_running.lock().unwrap() {
                    break;
                }

                let cutoff =
                    chrono::Utc::now() - chrono::Duration::seconds(SUGGESTION_CONTEXT_WINDOW_SECS);
                let recent_buf = suggestion_recent_utterances
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|u| u.timestamp >= cutoff)
                    .cloned()
                    .collect::<Vec<_>>();
                if recent_buf.is_empty() {
                    continue;
                }

                let latest_utterance_id = recent_buf.last().map(|u| u.id);
                if latest_utterance_id.is_none() || latest_utterance_id == last_checked_utterance_id
                {
                    continue;
                }
                last_checked_utterance_id = latest_utterance_id;

                let transcript_window = recent_buf
                    .iter()
                    .map(|u| match u.speaker {
                        Speaker::You => format!("You: {}", u.text),
                        Speaker::Them => format!("Them: {}", u.text),
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                if transcript_window.trim().is_empty() {
                    continue;
                }

                suggestion_app.emit("suggestion-generating", ()).ok();
                suggestion_app
                    .emit(
                        "suggestion-check-started",
                        &SuggestionCheckPayload {
                            checked_at: chrono::Utc::now().to_rfc3339(),
                            surfaced: false,
                        },
                    )
                    .ok();

                let settings = suggestion_state.settings.lock().unwrap().clone();
                let (embed_url, embed_key, embed_model) = embed_config(&settings);
                let (llm_url, llm_key) = llm_base_url_and_key(&settings);
                let llm_model = if settings.llm_provider == "ollama" {
                    settings.ollama_llm_model.clone()
                } else {
                    settings.selected_model.clone()
                };

                use opencassava_core::intelligence::knowledge_base::search_chunks;
                let kb_snapshot = suggestion_state.knowledge_base.lock().await.chunks.clone();

                let embed_fn = {
                    let url = embed_url.clone();
                    let key = embed_key.clone();
                    let model = embed_model.clone();
                    move |texts: Vec<String>| {
                        let url = url.clone();
                        let key = key.clone();
                        let model = model.clone();
                        async move {
                            opencassava_core::intelligence::embedding_client::embed(
                                &url,
                                key.as_deref(),
                                &model,
                                &texts,
                                None,
                                None,
                            )
                            .await
                        }
                    }
                };

                let search_fn = move |emb: &[f32]| -> Vec<opencassava_core::models::KBResult> {
                    search_chunks(&kb_snapshot, emb, 5, 0.4)
                };

                let complete_fn = {
                    let url = llm_url.clone();
                    let key = llm_key.clone();
                    let model = llm_model.clone();
                    move |messages: Vec<opencassava_core::intelligence::llm_client::Message>| {
                        let url = url.clone();
                        let key = key.clone();
                        let model = model.clone();
                        async move {
                            opencassava_core::intelligence::llm_client::complete(
                                &url,
                                key.as_deref(),
                                &model,
                                messages,
                                512,
                            )
                            .await
                        }
                    }
                };

                let recent_them = recent_buf
                    .iter()
                    .filter(|u| matches!(u.speaker, Speaker::Them))
                    .collect::<Vec<_>>();
                if recent_them.is_empty() || recent_buf.len() < 3 {
                    suggestion_app.emit("suggestion-finished", ()).ok();
                    continue;
                }

                let mut engine = suggestion_state.suggestion_engine.lock().await;
                let suggestion = engine
                    .process_transcript_window(
                        &transcript_window,
                        &recent_them,
                        embed_fn,
                        search_fn,
                        complete_fn,
                    )
                    .await;
                let surfaced = suggestion.is_some();

                if let Some(suggestion) = suggestion {
                    let payload = SuggestionPayload {
                        id: suggestion.id.to_string(),
                        kind: match suggestion.kind {
                            opencassava_core::models::SuggestionKind::KnowledgeBase => {
                                "knowledge_base".into()
                            }
                            opencassava_core::models::SuggestionKind::SmartQuestion => {
                                "smart_question".into()
                            }
                        },
                        text: suggestion.text.clone(),
                        kb_hits: suggestion.kb_hits.clone(),
                    };
                    *suggestion_state.overlay_suggestion.lock().unwrap() = Some(payload.clone());
                    suggestion_app.emit("suggestion", &payload).ok();
                    if let Ok(overlay) = ensure_overlay_window(&suggestion_app) {
                        let _ = overlay.show();
                        emit_overlay_suggestion(overlay, payload.clone());
                    }
                }

                suggestion_app
                    .emit(
                        "suggestion-check-finished",
                        &SuggestionCheckPayload {
                            checked_at: chrono::Utc::now().to_rfc3339(),
                            surfaced,
                        },
                    )
                    .ok();
                suggestion_app.emit("suggestion-finished", ()).ok();
            }
        });
        *state_clone.suggestion_task.lock().unwrap() = Some(suggestion_handle);

        // ── "You" mic capture ──────────────────────────────────────────────
        let mic = CpalMicCapture::new();
        let mic_stream = mic.buffer_stream_for_device(device_name.as_deref());
        use futures::StreamExt;
        let mic_level_w = Arc::clone(&state_clone.mic_level);
        let mic_stream_leveled = mic_stream.map(move |chunk: Vec<f32>| {
            let rms = compute_rms(&chunk);
            mic_level_w.store(rms.to_bits(), Ordering::Relaxed);
            chunk
        });
        let app_y = app_clone.clone();
        let state_y = Arc::clone(&state_clone);
        let on_you = move |text: String| {
            if !*state_y.is_running.lock().unwrap() {
                return;
            }
            let payload = TranscriptPayload {
                text: text.clone(),
                speaker: "you".into(),
            };
            app_y.emit("transcript", &payload).ok();
            push_recent_utterance(
                &recent_utterances,
                opencassava_core::models::Utterance {
                    id: uuid::Uuid::new_v4(),
                    text: text.clone(),
                    speaker: Speaker::You,
                    timestamp: chrono::Utc::now(),
                },
            );
            let record = SessionRecord {
                speaker: Speaker::You,
                text: text.clone(),
                timestamp: chrono::Utc::now(),
                suggestions: None,
                kb_hits: None,
                suggestion_decision: None,
                surfaced_suggestion_text: None,
                conversation_state_summary: None,
            };
            state_y
                .session_store
                .lock()
                .unwrap()
                .append_record(&record)
                .ok();
            state_y
                .transcript_logger
                .lock()
                .unwrap()
                .append("You", &text, chrono::Utc::now());
        };

        app_clone.emit("whisper-ready", ()).ok();
        let app_vol_y = app_clone.clone();
        let state_vol_y = Arc::clone(&state_clone);
        let on_you_vol = move |_text: String| {
            if !*state_vol_y.is_running.lock().unwrap() {
                return;
            }
            app_vol_y
                .emit(
                    "transcript-volatile",
                    &TranscriptPayload {
                        text: "...".into(),
                        speaker: "you".into(),
                    },
                )
                .ok();
        };
        let transcriber = StreamingTranscriber::new(model_str, language, Box::new(on_you))
            .with_volatile(Box::new(on_you_vol));
        transcriber.run(mic_stream_leveled).await;
    });

    *state.audio_task.lock().unwrap() = Some(handle);
    Ok(session_id)
}

#[tauri::command]
pub fn stop_transcription(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String> {
    if let Some(handle) = state.audio_task.lock().unwrap().take() {
        handle.abort();
    }
    if let Some(handle) = state.system_audio_task.lock().unwrap().take() {
        handle.abort();
    }
    if let Some(handle) = state.suggestion_task.lock().unwrap().take() {
        handle.abort();
    }
    if let Some(handle) = state.poll_task.lock().unwrap().take() {
        handle.abort();
    }
    state.session_store.lock().unwrap().end_session();
    state.transcript_logger.lock().unwrap().end_session();
    *state.overlay_suggestion.lock().unwrap() = None;
    if let Some(overlay) = app.get_webview_window(OVERLAY_LABEL) {
        let _ = overlay.hide();
    }
    *state.is_running.lock().unwrap() = false;
    state.mic_level.store(0u32, Ordering::Relaxed);
    state.sys_level.store(0u32, Ordering::Relaxed);
    Ok(())
}

#[tauri::command]
pub async fn download_model(app: AppHandle, model: String) -> Result<(), String> {
    let model_path = AppState::model_path_for(&app, &model)?;
    let app_clone = app.clone();
    let model_clone = model.clone();
    download::download_model(&model_clone, model_path, move |pct| {
        app_clone.emit("model-download-progress", pct).ok();
    })
    .await?;
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
    let records = state
        .session_store
        .lock()
        .unwrap()
        .load_transcript(&session_id);
    let transcript_chars: usize = records.iter().map(|record| record.text.len()).sum();
    log::info!(
        "generate_notes requested: session_id={}, template_id={:?}, utterances={}, transcript_chars={}",
        session_id,
        template_id,
        records.len(),
        transcript_chars
    );
    if records.is_empty() {
        log::warn!(
            "generate_notes aborted: transcript is empty for session_id={}",
            session_id
        );
        return Err(format!("No transcript found for session `{session_id}`."));
    }

    let template = template_id
        .as_deref()
        .and_then(|id| {
            MeetingTemplate::built_ins()
                .into_iter()
                .find(|template| template.id.to_string() == id)
        })
        .unwrap_or_else(|| MeetingTemplate::built_ins().into_iter().next().unwrap());
    let (base_url, api_key) = llm_base_url_and_key(&settings);
    let model = if settings.llm_provider == "ollama" {
        settings.ollama_llm_model.clone()
    } else {
        settings.selected_model.clone()
    };

    let app_c = app.clone();
    let on_chunk = move |chunk: String| {
        app_c.emit("notes-chunk", chunk).ok();
    };

    let result = notes_engine::generate_notes(
        &records,
        &template,
        &base_url,
        api_key.as_deref(),
        &model,
        on_chunk,
    )
    .await?;

    state.session_store.lock().unwrap().save_notes(
        &session_id,
        opencassava_core::models::EnhancedNotes {
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
pub fn update_kb_folder(folder: String, state: tauri::State<'_, Arc<AppState>>) {
    let mut s = state.settings.lock().unwrap();
    s.kb_folder_path = Some(folder);
    s.save();
}

#[tauri::command]
pub fn suggestion_feedback(
    session_id: Option<String>,
    suggestion_id: String,
    helpful: bool,
    state: tauri::State<'_, Arc<AppState>>,
) {
    log::info!(
        "suggestion_feedback: id={} helpful={}",
        suggestion_id,
        helpful
    );

    let session_id = session_id.or_else(|| {
        let session_store = state.session_store.lock().unwrap();
        session_store.current_session_id().map(str::to_owned)
    });

    if let Some(session_id) = session_id {
        state
            .session_store
            .lock()
            .unwrap()
            .save_suggestion_feedback(
                &session_id,
                SuggestionFeedbackEntry {
                    suggestion_id,
                    helpful,
                    created_at: chrono::Utc::now(),
                },
            );
    }
}

#[tauri::command]
pub fn show_overlay(app: AppHandle) -> Result<(), String> {
    let w = ensure_overlay_window(&app)?;
    w.show().map_err(|e| e.to_string())?;
    let _ = w.set_focus();
    Ok(())
}

#[tauri::command]
pub fn show_overlay_preview(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    id: String,
    text: String,
) -> Result<(), String> {
    *state.overlay_suggestion.lock().unwrap() = Some(SuggestionPayload {
        id,
        kind: "preview".into(),
        text,
        kb_hits: Vec::new(),
    });

    let w = ensure_overlay_window(&app)?;
    w.show().map_err(|e| e.to_string())?;
    let _ = w.set_focus();
    if let Some(payload) = state.overlay_suggestion.lock().unwrap().clone() {
        emit_overlay_suggestion(w, payload);
    }
    Ok(())
}

#[tauri::command]
pub fn hide_overlay(
    app: AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String> {
    *state.overlay_suggestion.lock().unwrap() = None;
    if let Some(w) = app.get_webview_window(OVERLAY_LABEL) {
        w.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn get_overlay_suggestion(
    state: tauri::State<'_, Arc<AppState>>,
) -> Option<SuggestionPayload> {
    state.overlay_suggestion.lock().unwrap().clone()
}

#[tauri::command]
pub fn set_overlay_position(app: AppHandle, x: i32, y: i32) -> Result<(), String> {
    if let Some(w) = app.get_webview_window(OVERLAY_LABEL) {
        w.set_position(tauri::Position::Physical(tauri::PhysicalPosition { x, y }))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_overlay_size(app: AppHandle, width: u32, height: u32) -> Result<(), String> {
    if let Some(w) = app.get_webview_window(OVERLAY_LABEL) {
        w.set_size(tauri::Size::Logical(tauri::LogicalSize {
            width: width as f64,
            height: height as f64,
        }))
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_content_protection(app: AppHandle, enabled: bool) -> Result<(), String> {
    for label in ["main", "overlay"] {
        if let Some(w) = app.get_webview_window(label) {
            w.set_content_protected(enabled)
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
pub async fn choose_folder(app: AppHandle) -> Option<String> {
    tokio::task::spawn_blocking(move || {
        app.dialog()
            .file()
            .blocking_pick_folder()
            .and_then(|f| f.into_path().ok())
            .map(|p| p.to_string_lossy().into_owned())
    })
    .await
    .ok()
    .flatten()
}

#[tauri::command]
pub fn list_sessions(
    state: tauri::State<'_, Arc<AppState>>,
) -> Vec<opencassava_core::models::SessionIndex> {
    state.session_store.lock().unwrap().load_session_index()
}

#[tauri::command]
pub fn load_session(
    id: String,
    state: tauri::State<'_, Arc<AppState>>,
) -> SessionDetailsPayload {
    let store = state.session_store.lock().unwrap();
    SessionDetailsPayload {
        transcript: store.load_transcript(&id),
        notes: store.load_notes(&id),
    }
}

#[tauri::command]
pub fn load_session_notes(
    id: String,
    state: tauri::State<'_, Arc<AppState>>,
) -> Option<EnhancedNotes> {
    state.session_store.lock().unwrap().load_notes(&id)
}

#[tauri::command]
pub fn list_templates(state: tauri::State<'_, Arc<AppState>>) -> Vec<MeetingTemplate> {
    state.template_store.lock().unwrap().templates().to_vec()
}

#[tauri::command]
pub fn save_template(
    template: MeetingTemplate,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String> {
    let mut store = state.template_store.lock().unwrap();
    if store.get(template.id).is_some() {
        store.update(template);
    } else {
        store.add(template);
    }
    Ok(())
}

#[tauri::command]
pub fn delete_template(id: String, state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    let uuid = uuid::Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.template_store.lock().unwrap().delete(uuid);
    Ok(())
}

#[tauri::command]
pub async fn save_transcript(
    app: AppHandle,
    content: String,
    default_name: String,
) -> Result<(), String> {
    use tauri_plugin_dialog::DialogExt;
    
    let file_path = tokio::task::spawn_blocking(move || {
        app.dialog()
            .file()
            .set_file_name(&default_name)
            .add_filter("Markdown", &["md"])
            .add_filter("Text", &["txt"])
            .add_filter("JSON", &["json"])
            .blocking_save_file()
    })
    .await
    .map_err(|e| e.to_string())?
    .ok_or("No file selected")?;
    
    let path = file_path.into_path().map_err(|e| e.to_string())?;
    tokio::fs::write(&path, content).await.map_err(|e| e.to_string())?;
    
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
