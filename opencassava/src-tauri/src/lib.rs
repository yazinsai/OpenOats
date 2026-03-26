#[cfg(target_os = "macos")]
mod audio_macos;
mod audio_windows;
mod engine;

use std::sync::Arc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = Arc::new(engine::AppState::new());
    let setup_state = Arc::clone(&state);

    // Pre-warm Parakeet workers in the background so the model is loaded before the
    // user clicks record for the first time. The handle is retrieved inside setup
    // where |app| is available.
    let _warmup_state = Arc::clone(&state);

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            engine::check_model,
            engine::get_model_path,
            engine::get_stt_status,
            engine::get_settings,
            engine::get_api_keys,
            engine::save_settings,
            engine::save_api_keys,
            engine::list_mic_devices,
            engine::list_sys_audio_devices,
            engine::start_transcription,
            engine::stop_transcription,
            engine::download_model,
            engine::download_stt_model,
            engine::generate_notes,
            engine::index_kb,
            engine::update_kb_folder,
            engine::suggestion_feedback,
            engine::show_overlay,
            engine::show_overlay_preview,
            engine::hide_overlay,
            engine::get_overlay_suggestion,
            engine::set_overlay_position,
            engine::set_overlay_size,
            engine::set_content_protection,
            engine::choose_folder,
            engine::list_templates,
            engine::save_template,
            engine::delete_template,
            engine::reset_template,
            engine::get_default_suggestion_prompts,
            engine::list_sessions,
            engine::load_session,
            engine::load_session_notes,
            engine::save_transcript,
            engine::start_calibration_preview,
            engine::stop_calibration_preview,
            engine::calibrate_mic_threshold,
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                if window.label() == "main" {
                    window.app_handle().exit(0);
                }
            }
        })
        .setup(move |app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            let hide_from_screen_share =
                setup_state.settings.lock().unwrap().hide_from_screen_share;
            engine::set_content_protection(app.handle().clone(), hide_from_screen_share)
                .map_err(|err| std::io::Error::other(err))?;
            // Pre-warm Parakeet workers so the model is loaded before the user first clicks record.
            engine::warm_parakeet_workers(Arc::clone(&_warmup_state), app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
