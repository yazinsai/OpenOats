#[cfg(target_os = "macos")]
mod audio_macos;
mod audio_windows;
mod engine;

use std::sync::Arc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = Arc::new(engine::AppState::new());
    let setup_state = Arc::clone(&state);

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            engine::check_model,
            engine::get_model_path,
            engine::get_settings,
            engine::get_api_keys,
            engine::save_settings,
            engine::save_api_keys,
            engine::list_mic_devices,
            engine::list_sys_audio_devices,
            engine::start_transcription,
            engine::stop_transcription,
            engine::download_model,
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
            engine::list_sessions,
            engine::load_session,
            engine::load_session_notes,
            engine::save_transcript,
        ])
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
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
