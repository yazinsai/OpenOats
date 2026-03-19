mod audio_windows;
mod engine;

use std::sync::Arc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = Arc::new(engine::AppState::new());

    tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            engine::check_model,
            engine::get_model_path,
            engine::get_settings,
            engine::get_api_keys,
            engine::save_settings,
            engine::save_api_keys,
            engine::list_mic_devices,
            engine::start_transcription,
            engine::stop_transcription,
            engine::download_model,
            engine::generate_notes,
            engine::index_kb,
            engine::update_kb_folder,
        ])
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
