# Audio Device Selection & Language Model Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add system audio device selector to ControlBar, remove duplicate mic selector from Settings, and fix the language selector by adding a Whisper model toggle (English-only vs multilingual).

**Architecture:** Three layers of changes — (1) `openoats-core` gains model/URL helpers and updated download API, (2) the Tauri `engine.rs` layer gains new/updated commands and wires new settings into audio capture, (3) the React frontend adds the system audio dropdown and model radio while removing the broken duplicate.

**Tech Stack:** Rust (workspace: `OpenOats/OpenOats/`), React + TypeScript (Tauri frontend: `OpenOats/OpenOats/OpenOatsTauri/`), windows crate 0.54 for WASAPI enumeration.

**Spec:** `docs/superpowers/specs/2026-03-19-audio-language-fixes-design.md`

**All shell commands run from workspace root:** `C:\Users\ejrom\exa-tec\OpenOats\OpenOats\` unless noted.

---

## File Map

| File | Change |
|---|---|
| `crates/openoats-core/src/download.rs` | Add `pub fn model_filename`, `fn model_url`; update `download_model` to accept `model: &str` param |
| `crates/openoats-core/src/settings.rs` | Add `whisper_model` and `system_audio_device_name` fields with custom serde defaults |
| `OpenOatsTauri/src-tauri/src/engine.rs` | Update `check_model` + `download_model` commands (add `model` param); add `list_sys_audio_devices`; update `start_transcription` |
| `OpenOatsTauri/src-tauri/src/audio_windows.rs` | Add `list_render_devices()` fn; update `WasapiLoopback::new()` to accept `device_name: Option<&str>` |
| `OpenOatsTauri/src-tauri/src/lib.rs` | Register `list_sys_audio_devices` in `invoke_handler!` |
| `OpenOatsTauri/src-tauri/Cargo.toml` | Add `Win32_Devices_Properties` windows feature |
| `OpenOatsTauri/src/types.ts` | Add `systemAudioDeviceName` and `whisperModel` to `AppSettings` |
| `OpenOatsTauri/src/App.tsx` | Fix `check_model` call site; fix `download_model` call site; pass `isRunning` to `SettingsView` |
| `OpenOatsTauri/src/components/ControlBar.tsx` | Add system audio `<select>` |
| `OpenOatsTauri/src/components/SettingsView.tsx` | Remove duplicate mic selector; add `whisperModel` radio group; accept `isRunning` prop |

---

## Task 1: Add `model_filename` and `model_url` helpers; update `download_model` signature

**Files:**
- Modify: `crates/openoats-core/src/download.rs`

Context: `download_model` currently hardcodes a single URL constant. We need it to accept a model identifier (`"base-en"` or `"base"`) and download the correct file.

- [ ] **Step 1: Write failing tests**

Add to the `#[cfg(test)]` block at the bottom of `crates/openoats-core/src/download.rs`:

```rust
#[test]
fn model_filename_base_en() {
    assert_eq!(model_filename("base-en"), "ggml-base.en.bin");
}

#[test]
fn model_filename_base() {
    assert_eq!(model_filename("base"), "ggml-base.bin");
}

#[test]
fn model_filename_unknown_defaults_to_en() {
    assert_eq!(model_filename("garbage"), "ggml-base.en.bin");
}

#[test]
fn model_url_base_en_points_to_hf() {
    assert!(model_url("base-en").contains("ggml-base.en.bin"));
}

#[test]
fn model_url_base_points_to_hf() {
    assert!(model_url("base").contains("ggml-base.bin"));
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cargo test -p openoats-core model_filename
```

Expected: `error[E0425]: cannot find function 'model_filename'`

- [ ] **Step 3: Implement helpers and update `download_model`**

Replace the top of `crates/openoats-core/src/download.rs` (the `MODEL_URL` constant and the `download_model` function signature/body) with:

```rust
pub fn model_filename(whisper_model: &str) -> &'static str {
    match whisper_model {
        "base" => "ggml-base.bin",
        _ => "ggml-base.en.bin",
    }
}

fn model_url(whisper_model: &str) -> &'static str {
    match whisper_model {
        "base" => "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        _ => "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
    }
}

pub fn model_exists(path: &Path) -> bool {
    path.exists()
}

/// Download a Whisper model to `dest`, emitting progress via `on_progress(pct: u32)`.
/// `model` is `"base-en"` or `"base"`. Uses `.tmp` then atomic rename.
pub async fn download_model<F>(model: &str, dest: PathBuf, on_progress: F) -> Result<(), String>
where
    F: Fn(u32) + Send + 'static,
{
    use reqwest::Client;
    use tokio::io::AsyncWriteExt;

    if dest.exists() {
        return Ok(());
    }

    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let url = model_url(model);
    let client = Client::new();
    let resp = client.get(url).send().await.map_err(|e| e.to_string())?;

    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let total = resp.content_length().unwrap_or(0);
    let mut stream = resp.bytes_stream();
    let tmp = dest.with_extension("tmp");
    let mut file = tokio::fs::File::create(&tmp).await.map_err(|e| e.to_string())?;

    let mut downloaded: u64 = 0;
    use futures::StreamExt;
    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| e.to_string())?;
        file.write_all(&bytes).await.map_err(|e| e.to_string())?;
        downloaded += bytes.len() as u64;
        if total > 0 {
            on_progress((downloaded * 100 / total) as u32);
        }
    }

    file.flush().await.map_err(|e| e.to_string())?;
    drop(file);
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    log::info!("Model downloaded to {}", dest.display());
    Ok(())
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cargo test -p openoats-core model_filename
cargo test -p openoats-core model_url
```

Expected: all 5 tests pass.

- [ ] **Step 5: Check compile**

```bash
cargo check -p openoats-core
```

Expected: no errors. (The caller in `engine.rs` will break — fixed in Task 3.)

- [ ] **Step 6: Commit**

```bash
git add crates/openoats-core/src/download.rs
git commit -m "feat: add model_filename/model_url helpers; parameterise download_model by model"
```

---

## Task 2: Add `whisper_model` and `system_audio_device_name` to `AppSettings`

**Files:**
- Modify: `crates/openoats-core/src/settings.rs`

Context: The `AppSettings` struct uses a consistent pattern — every field has a `#[serde(default = "fn_name")]` attribute pointing to a named function. Follow exactly this pattern. The `Default` impl is also hand-written (not derived) so we need to add both fields there too.

- [ ] **Step 1: Write failing tests**

Add to the `#[cfg(test)]` block at the bottom of `crates/openoats-core/src/settings.rs`:

```rust
#[test]
fn whisper_model_defaults_to_base_en() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("nonexistent.json");
    let s = AppSettings::load_from(path);
    assert_eq!(s.whisper_model, "base-en");
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
    assert_eq!(s.whisper_model, "base-en");
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
    assert_eq!(s2.system_audio_device_name.as_deref(), Some("Speakers (Realtek)"));
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cargo test -p openoats-core whisper_model
cargo test -p openoats-core system_audio
```

Expected: `error[E0609]: no field 'whisper_model'`

- [ ] **Step 3: Add fields to `AppSettings`**

In `crates/openoats-core/src/settings.rs`:

**3a.** In the `AppSettings` struct, after the `input_device_name` field (around line 17), add:

```rust
#[serde(default = "default_whisper_model", alias = "whisper_model")]
pub whisper_model: String,

#[serde(default, alias = "system_audio_device_name")]
pub system_audio_device_name: Option<String>,
```

**3b.** In the `Default` impl's `Self { ... }` block (around line 99), add:

```rust
whisper_model: default_whisper_model(),
system_audio_device_name: None,
```

**3c.** At the bottom of the file, alongside the other `fn default_*` functions, add:

```rust
fn default_whisper_model() -> String { "base-en".into() }
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cargo test -p openoats-core whisper_model
cargo test -p openoats-core system_audio
cargo test -p openoats-core settings
```

Expected: all pass.

- [ ] **Step 5: Check compile**

```bash
cargo check -p openoats-core
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add crates/openoats-core/src/settings.rs
git commit -m "feat: add whisper_model and system_audio_device_name to AppSettings"
```

---

## Task 3: Update `check_model` and `download_model` Tauri commands; fix `AppState::model_path`

**Files:**
- Modify: `OpenOatsTauri/src-tauri/src/engine.rs`

Context: Both commands now accept an explicit `model: String` parameter. `AppState::model_path` currently hardcodes `ggml-base.en.bin` — replace it with a `model_path_for` helper that takes the model name. The `start_transcription` call to `model_path` is updated in Task 5; here we just fix the command-level wiring.

- [ ] **Step 1: Update `AppState::model_path` to `model_path_for`**

In `engine.rs`, replace:

```rust
pub fn model_path(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|p| p.join("ggml-base.en.bin"))
        .map_err(|e| e.to_string())
}
```

with:

```rust
pub fn model_path_for(app: &AppHandle, model: &str) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|p| p.join(openoats_core::download::model_filename(model)))
        .map_err(|e| e.to_string())
}
```

- [ ] **Step 2: Update `check_model` command**

Replace:

```rust
#[tauri::command]
pub fn check_model(app: AppHandle) -> Result<bool, String> {
    let path = AppState::model_path(&app)?;
    Ok(download::model_exists(&path))
}
```

with:

```rust
#[tauri::command]
pub fn check_model(app: AppHandle, model: String) -> Result<bool, String> {
    let path = AppState::model_path_for(&app, &model)?;
    Ok(download::model_exists(&path))
}
```

- [ ] **Step 3: Update `get_model_path` command**

Replace:

```rust
#[tauri::command]
pub fn get_model_path(app: AppHandle) -> Result<String, String> {
    AppState::model_path(&app).map(|p| p.to_string_lossy().into_owned())
}
```

with:

```rust
#[tauri::command]
pub fn get_model_path(app: AppHandle, model: String) -> Result<String, String> {
    AppState::model_path_for(&app, &model).map(|p| p.to_string_lossy().into_owned())
}
```

- [ ] **Step 4: Update `download_model` command**

Replace:

```rust
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
```

with:

```rust
#[tauri::command]
pub async fn download_model(app: AppHandle, model: String) -> Result<(), String> {
    let model_path = AppState::model_path_for(&app, &model)?;
    let app_clone = app.clone();
    let model_clone = model.clone();
    download::download_model(&model_clone, model_path, move |pct| {
        app_clone.emit("model-download-progress", pct).ok();
    }).await?;
    app.emit("model-download-done", ()).ok();
    Ok(())
}
```

- [ ] **Step 5: Compile check**

```bash
cargo check -p app
```

Expected: two compile errors — (1) `start_transcription` still calls `AppState::model_path`, fixed in Task 5; (2) the `engine.rs` `download_model` command body still calls the old `download::download_model(model_path, ...)` signature (no model arg) which was updated in this step. Both should be resolved by this task's Steps 3–4. If other errors appear, fix them now.

- [ ] **Step 6: Commit**

```bash
git add OpenOatsTauri/src-tauri/src/engine.rs
git commit -m "feat: add model param to check_model, download_model commands"
```

---

## Task 4: Add Windows device enumeration + `list_sys_audio_devices` command

**Files:**
- Modify: `OpenOatsTauri/src-tauri/src/audio_windows.rs`
- Modify: `OpenOatsTauri/src-tauri/src/engine.rs`
- Modify: `OpenOatsTauri/src-tauri/src/lib.rs`
- Modify: `OpenOatsTauri/src-tauri/Cargo.toml`

Context: We need to enumerate WASAPI render (output/loopback) endpoints by friendly name. This uses `IMMDeviceEnumerator::EnumAudioEndpoints` and reads each device's `PKEY_Device_FriendlyName` property. We also need to update `WasapiLoopback::new()` to accept an optional device name and look up that device instead of always using the default. There are no unit tests for WASAPI code (requires hardware), so we verify by compile + manual smoke test.

- [ ] **Step 1: Add windows feature for device properties**

In `OpenOatsTauri/src-tauri/Cargo.toml`, in the `[target.'cfg(windows)'.dependencies]` windows features list, add:

```toml
"Win32_Devices_Properties",
```

- [ ] **Step 2: Add device enumeration to `audio_windows.rs`**

In the `#[cfg(target_os = "windows")] mod wasapi_impl` block, add the following imports at the top (note: `STGM_READ` is in `Com`, not `StructuredStorage`):

```rust
use windows::Win32::Devices::Properties::PKEY_Device_FriendlyName;
use windows::Win32::System::Com::StructuredStorage::PropVariantClear;
use windows::Win32::System::Com::STGM_READ;
use windows::Win32::System::Variant::VT_LPWSTR;
```

Then add this helper function inside `wasapi_impl` (before the `pub use` line):

```rust
/// Returns friendly names of all active render (output/loopback) endpoints.
pub fn list_render_devices() -> Vec<String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let enumerator: IMMDeviceEnumerator =
            match CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) {
                Ok(e) => e,
                Err(_) => return vec![],
            };
        let collection = match enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) {
            Ok(c) => c,
            Err(_) => return vec![],
        };
        let count = collection.GetCount().unwrap_or(0);
        let mut names = Vec::new();
        for i in 0..count {
            if let Ok(device) = collection.Item(i) {
                if let Ok(store) = device.OpenPropertyStore(STGM_READ) {
                    let mut prop = Default::default();
                    if store.GetValue(&PKEY_Device_FriendlyName, &mut prop).is_ok() {
                        let vt = prop.Anonymous.Anonymous.vt;
                        if vt.0 == VT_LPWSTR.0 {
                            let pwstr = prop.Anonymous.Anonymous.Anonymous.pwszVal;
                            if let Ok(s) = pwstr.to_string() {
                                names.push(s);
                            }
                        }
                        let _ = PropVariantClear(&mut prop);
                    }
                }
            }
        }
        names
    }
}

/// Find a render device by its friendly name. Returns None if not found.
unsafe fn find_device_by_name(
    enumerator: &IMMDeviceEnumerator,
    name: &str,
) -> Option<IMMDevice> {
    let collection = enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE).ok()?;
    let count = collection.GetCount().ok()?;
    for i in 0..count {
        if let Ok(device) = collection.Item(i) {
            if let Ok(store) = device.OpenPropertyStore(STGM_READ) {
                let mut prop = Default::default();
                if store.GetValue(&PKEY_Device_FriendlyName, &mut prop).is_ok() {
                    let vt = prop.Anonymous.Anonymous.vt;
                    let matched = if vt.0 == VT_LPWSTR.0 {
                        let pwstr = prop.Anonymous.Anonymous.Anonymous.pwszVal;
                        pwstr.to_string().ok().as_deref() == Some(name)
                    } else {
                        false
                    };
                    let _ = PropVariantClear(&mut prop);
                    if matched {
                        return Some(device);
                    }
                }
            }
        }
    }
    None
}
```

- [ ] **Step 3: Update `WasapiLoopback::new()` to accept device name**

Change the `WasapiLoopback` struct to store the device name:

```rust
pub struct WasapiLoopback {
    finished: Arc<AtomicBool>,
    audio_level: Arc<std::sync::Mutex<f32>>,
    device_name: Option<String>,
}
```

Update `new()`:

```rust
impl WasapiLoopback {
    pub fn new(device_name: Option<&str>) -> Self {
        Self {
            finished: Arc::new(AtomicBool::new(false)),
            audio_level: Arc::new(std::sync::Mutex::new(0.0)),
            device_name: device_name.map(str::to_owned),
        }
    }
}
```

Update `buffer_stream` to clone the device name from `self` **before** the `std::thread::spawn` call, then move it into the closure. The existing `buffer_stream` method starts with the `finished` and `level_arc` clones — add the device name clone right alongside them:

```rust
async fn buffer_stream(&self) -> Result<AudioStream, Box<dyn Error + Send + Sync>> {
    let finished = self.finished.clone();
    let level_arc = self.audio_level.clone();
    let device_name_inner = self.device_name.clone();   // ← add this line
    let (tx, rx) = mpsc::channel::<Vec<f32>>(200);

    std::thread::spawn(move || {
        unsafe {
            // ... CoInitializeEx, MMDeviceEnumerator CoCreateInstance ... (unchanged)

            // Replace the existing `let device = match enumerator.GetDefaultAudioEndpoint(...)` block:
            let device = if let Some(ref name) = device_name_inner {
                find_device_by_name(&enumerator, name)
                    .unwrap_or_else(|| {
                        log::warn!(
                            "System audio device '{}' not found, falling back to default", name
                        );
                        enumerator
                            .GetDefaultAudioEndpoint(eRender, eConsole)
                            .expect("no default render endpoint")
                    })
            } else {
                match enumerator.GetDefaultAudioEndpoint(eRender, eConsole) {
                    Ok(d) => d,
                    Err(e) => { log::error!("WASAPI: GetDefaultAudioEndpoint: {e}"); return; }
                }
            };

            // ... rest of the existing thread body (Activate, GetMixFormat, Initialize, etc.) is unchanged
        }
    });
    // ...
}
```

Everything after `let device = ...` in the original (`Activate`, `GetMixFormat`, `Initialize`, capture loop) is **unchanged** — only the device acquisition block is replaced.

- [ ] **Step 4: Update the non-Windows stub**

In `#[cfg(not(target_os = "windows"))] mod wasapi_impl`, update `SystemAudioCapture::new()`:

```rust
impl SystemAudioCapture {
    pub fn new(_device_name: Option<&str>) -> Self { Self }
}

pub fn list_render_devices() -> Vec<String> { vec![] }
```

- [ ] **Step 5: Re-export `list_render_devices` from `audio_windows.rs` and add command to `engine.rs`**

**5a.** At the bottom of `audio_windows.rs`, add a single unconditional re-export (both cfg branches define `list_render_devices`, so no cfg guard needed here):

```rust
pub use wasapi_impl::list_render_devices;
```

**5b.** In `engine.rs`, near `list_mic_devices`, add:

```rust
#[tauri::command]
pub fn list_sys_audio_devices() -> Vec<String> {
    crate::audio_windows::list_render_devices()
}
```

- [ ] **Step 6: Register in `lib.rs`**

In `OpenOatsTauri/src-tauri/src/lib.rs`, add `engine::list_sys_audio_devices` to the `invoke_handler!` macro list (after `engine::list_mic_devices`):

```rust
engine::list_sys_audio_devices,
```

- [ ] **Step 7: Compile check**

```bash
cargo check -p app
```

Expected: no errors. If PROPVARIANT types don't resolve, verify that `Win32_Devices_Properties` was added to Cargo.toml and that the imports in Step 2 are exactly as shown (especially `STGM_READ` from `Com`, not `StructuredStorage`).

- [ ] **Step 8: Commit**

```bash
git add OpenOatsTauri/src-tauri/src/audio_windows.rs \
        OpenOatsTauri/src-tauri/src/engine.rs \
        OpenOatsTauri/src-tauri/src/lib.rs \
        OpenOatsTauri/src-tauri/Cargo.toml
git commit -m "feat: add list_sys_audio_devices command and WasapiLoopback device selection"
```

---

## Task 5: Wire `whisper_model` and `system_audio_device_name` into `start_transcription`

**Files:**
- Modify: `OpenOatsTauri/src-tauri/src/engine.rs`

Context: `start_transcription` reads `settings.input_device_name` for the mic. It needs to also read `settings.system_audio_device_name` for the system audio capture, and use `settings.whisper_model` to resolve the model path (replacing the old `AppState::model_path` call).

- [ ] **Step 1: Update `start_transcription` to use `model_path_for`**

In `start_transcription`, find:

```rust
let model_path = AppState::model_path(&app)?;
if !download::model_exists(&model_path) {
    return Err("Whisper model not found. Download it first.".into());
}
```

Replace with:

```rust
let whisper_model = state.settings.lock().unwrap().whisper_model.clone();
let model_path = AppState::model_path_for(&app, &whisper_model)?;
if !download::model_exists(&model_path) {
    let filename = download::model_filename(&whisper_model);
    return Err(format!(
        "Whisper model not found: {}. Download it in Settings > Advanced > Transcription.",
        filename
    ));
}
```

- [ ] **Step 2: Pass `system_audio_device_name` to `SystemAudioCapture::new()`**

In `start_transcription`, find where the settings are read:

```rust
let settings = state.settings.lock().unwrap().clone();
let device_name = settings.input_device_name.clone();
let language = settings.transcription_locale
    .split('-').next().unwrap_or("en").to_string();
```

Add after `device_name`:

```rust
let sys_device_name = settings.system_audio_device_name.clone();
```

Then find the line inside the async block:

```rust
let sys = SystemAudioCapture::new();
```

Replace with:

```rust
let sys = SystemAudioCapture::new(sys_device_name.as_deref());
```

Note: `sys_device_name` is already cloned outside the async block so it's owned. Pass it into the `async move` closure by moving it.

- [ ] **Step 3: Compile check + run tests**

```bash
cargo check -p app
cargo test -p openoats-core
cargo test -p app
```

Expected: all pass, no errors.

- [ ] **Step 4: Commit**

```bash
git add OpenOatsTauri/src-tauri/src/engine.rs
git commit -m "feat: wire whisper_model and system_audio_device_name into start_transcription"
```

---

## Task 6: Update `types.ts` with new `AppSettings` fields

**Files:**
- Modify: `OpenOatsTauri/src/types.ts`

Context: The Rust `AppSettings` struct now has two new fields serialized as camelCase. The TypeScript interface must match or the frontend will treat them as `undefined`.

- [ ] **Step 1: Add fields to `AppSettings`**

In `OpenOatsTauri/src/types.ts`, in the `AppSettings` interface, add after `inputDeviceName`:

```typescript
systemAudioDeviceName: string | null;
whisperModel: string;
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
cd OpenOatsTauri && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
cd ..
git add OpenOatsTauri/src/types.ts
git commit -m "feat: add systemAudioDeviceName and whisperModel to AppSettings TS type"
```

---

## Task 7: Update `SettingsView.tsx` — remove duplicate mic selector; add model radio

**Files:**
- Modify: `OpenOatsTauri/src/components/SettingsView.tsx`

Context: (1) The "Audio Input" section in the Advanced tab is a broken duplicate — delete it. (2) Add a `whisperModel` radio group below the locale input. (3) Accept `isRunning: boolean` prop. This task comes before Task 9 (App.tsx) so the prop is available when App.tsx passes it.

- [ ] **Step 1: Add `isRunning` prop and radio state**

In `SettingsView.tsx`, update the component signature from:

```typescript
export function SettingsView() {
```

to:

```typescript
export function SettingsView({ isRunning }: { isRunning: boolean }) {
```

Add state for model readiness after the existing state declarations (`settings`, `apiKeys`, etc.):

```typescript
const [baseEnReady, setBaseEnReady] = useState<boolean | null>(null);
const [baseReady, setBaseReady] = useState<boolean | null>(null);
const [downloadingModel, setDownloadingModel] = useState<string | null>(null);
```

- [ ] **Step 2: Check both models on mount**

In the existing `useEffect` that calls `Promise.all([invoke<AppSettings>("get_settings"), invoke<ApiKeys>("get_api_keys")])`, after the `.then(([loadedSettings, loadedKeys]) => { ... })` block, chain a parallel model readiness check:

```typescript
Promise.all([
  invoke<boolean>("check_model", { model: "base-en" }),
  invoke<boolean>("check_model", { model: "base" }),
]).then(([en, multi]) => {
  setBaseEnReady(en);
  setBaseReady(multi);
}).catch(() => {});
```

- [ ] **Step 3: Remove the duplicate "Audio Input" section**

In the Advanced tab JSX (inside `{activeTab === "advanced" && ( ... )}`), find and delete the entire block:

```tsx
<div style={styles.divider} />

{/* Audio Section */}
<div style={styles.section}>
  <h4 style={styles.sectionTitle}>Audio Input</h4>
  <div style={styles.fieldWrap}>
    <label style={styles.labelStyle}>Microphone</label>
    <select
      value={settings.inputDeviceName || "default"}
      onChange={(e) =>
        saveSettings({ ...settings, inputDeviceName: e.target.value === "default" ? undefined : e.target.value })
      }
      style={styles.selectStyle}
    >
      <option value="default">System Default</option>
      {/* Device list would be populated here */}
    </select>
  </div>
</div>
```

Delete it entirely including its preceding `<div style={styles.divider} />`.

- [ ] **Step 4: Add model radio group below the locale input**

In the Transcription section, after the locale `<div style={styles.fieldWrap}>` block closes, add:

```tsx
<div style={styles.fieldWrap}>
  <label style={styles.labelStyle}>Whisper Model</label>
  <div style={{ display: "flex", flexDirection: "column", gap: spacing[2], opacity: isRunning ? 0.5 : 1, pointerEvents: isRunning ? "none" : "auto" }}>
    {/* English only */}
    <label style={{ display: "flex", alignItems: "center", gap: spacing[2], cursor: "pointer" }}>
      <input
        type="radio"
        name="whisperModel"
        value="base-en"
        checked={settings.whisperModel === "base-en"}
        onChange={() => saveSettings({ ...settings, whisperModel: "base-en" })}
        style={styles.checkboxInput}
      />
      <span style={styles.checkboxLabel}>English only (base-en)</span>
      {baseEnReady === true && (
        <span style={styles.statusBadge("success")}>✓ ready</span>
      )}
      {baseEnReady === false && (
        <button
          style={styles.buttonSecondary}
          onClick={async () => {
            setDownloadingModel("base-en");
            try {
              await invoke("download_model", { model: "base-en" });
              const ok = await invoke<boolean>("check_model", { model: "base-en" });
              setBaseEnReady(ok);
            } finally {
              setDownloadingModel(null);
            }
          }}
          disabled={downloadingModel !== null}
        >
          {downloadingModel === "base-en" ? "Downloading…" : "Download"}
        </button>
      )}
    </label>

    {/* Multilingual */}
    <label style={{ display: "flex", alignItems: "center", gap: spacing[2], cursor: "pointer" }}>
      <input
        type="radio"
        name="whisperModel"
        value="base"
        checked={settings.whisperModel === "base"}
        onChange={() => saveSettings({ ...settings, whisperModel: "base" })}
        style={styles.checkboxInput}
      />
      <span style={styles.checkboxLabel}>Multilingual (base) — supports all languages</span>
      {baseReady === true && (
        <span style={styles.statusBadge("success")}>✓ ready</span>
      )}
      {baseReady === false && (
        <button
          style={styles.buttonSecondary}
          onClick={async () => {
            setDownloadingModel("base");
            try {
              await invoke("download_model", { model: "base" });
              const ok = await invoke<boolean>("check_model", { model: "base" });
              setBaseReady(ok);
            } finally {
              setDownloadingModel(null);
            }
          }}
          disabled={downloadingModel !== null}
        >
          {downloadingModel === "base" ? "Downloading…" : "Download ~142 MB"}
        </button>
      )}
    </label>
  </div>
  <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
    Takes effect on next recording start. Language selector requires Multilingual model.
  </span>
</div>
```

- [ ] **Step 5: Verify TypeScript compiles**

```bash
cd OpenOatsTauri && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
cd ..
git add OpenOatsTauri/src/components/SettingsView.tsx
git commit -m "feat: remove duplicate mic selector; add whisperModel radio to Settings"
```

---

## Task 8: Add system audio device selector to `ControlBar.tsx`

**Files:**
- Modify: `OpenOatsTauri/src/components/ControlBar.tsx`

Context: `ControlBar` already has a mic device `<select>` that calls `list_mic_devices` on mount and saves via `get_settings` + `save_settings`. The system audio selector follows the same pattern. `isRunning` is already a pre-existing prop — no new props needed.

- [ ] **Step 1: Add state and load devices**

In `ControlBar.tsx`, after the existing state declarations (`devices`, `selectedDevice`, etc.), add:

```typescript
const [sysDevices, setSysDevices] = useState<string[]>([]);
const [selectedSysDevice, setSelectedSysDevice] = useState<string>("default");
```

Replace the existing `useEffect` (the one with `[]` deps that calls `list_mic_devices`) with the expanded version below. It adds sys device loading and initialises both selectors from saved settings:

```typescript
useEffect(() => {
  Promise.all([
    invoke<string[]>("list_mic_devices"),
    invoke<string[]>("list_sys_audio_devices"),
    invoke<any>("get_settings"),
  ]).then(([mics, sysDevs, s]) => {
    setDevices(mics);
    setSysDevices(sysDevs);
    if (s.inputDeviceName) setSelectedDevice(s.inputDeviceName);
    if (s.systemAudioDeviceName) setSelectedSysDevice(s.systemAudioDeviceName);
  });
}, []);
```

- [ ] **Step 2: Add `handleSysDeviceChange` handler**

After the existing `handleDeviceChange` function, add:

```typescript
const handleSysDeviceChange = async (device: string) => {
  setSelectedSysDevice(device);
  try {
    const settings = await invoke<any>("get_settings");
    await invoke("save_settings", {
      newSettings: {
        ...settings,
        systemAudioDeviceName: device === "default" ? null : device,
      },
    });
  } catch (e) {
    console.error("Failed to save sys audio device:", e);
  }
};
```

- [ ] **Step 3: Add the `<select>` element**

In the JSX return, after the existing mic `<select>` block (which ends around line 235), add:

```tsx
{/* System Audio Selector */}
<select
  value={selectedSysDevice}
  onChange={(e) => handleSysDeviceChange(e.target.value)}
  disabled={isRunning}
  style={{
    padding: `${spacing[2]}px`,
    background: colors.background,
    color: colors.text,
    border: `1px solid ${colors.border}`,
    borderRadius: 4,
    fontSize: typography.base,
    minWidth: 140,
    cursor: isRunning ? "not-allowed" : "pointer",
    opacity: isRunning ? 0.6 : 1,
  }}
>
  <option value="default">System Audio</option>
  {sysDevices.map((d) => (
    <option key={d} value={d}>
      {d}
    </option>
  ))}
</select>
```

- [ ] **Step 4: Verify TypeScript compiles**

```bash
cd OpenOatsTauri && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd ..
git add OpenOatsTauri/src/components/ControlBar.tsx
git commit -m "feat: add system audio device selector to ControlBar"
```

---

## Task 9: Fix `App.tsx` call sites; pass `isRunning` to `SettingsView`

**Files:**
- Modify: `OpenOatsTauri/src/App.tsx`

Context: Two existing call sites — `check_model()` on boot (~line 46) and `download_model()` (~line 119) — need the `model` argument. Also `<SettingsView />` needs `isRunning`. Comes after Task 7 so SettingsView already accepts the prop.

- [ ] **Step 1: Fix `check_model` call — merge settings load and model check into one effect**

In `App.tsx`, the current code has two separate `useEffect` hooks with `[]` deps:
- Effect 1 (~line 38): loads settings via `get_settings` → calls `setSettings`
- Effect 2 (~line 45): calls `check_model()` and registers all event listeners

Merge them so settings are loaded before the model check. Replace **both** effects with a single `useEffect`:

```typescript
useEffect(() => {
  // Load settings first, then check whichever model is selected
  invoke<AppSettings>("get_settings")
    .then((s) => {
      setSettings(s);
      const model = s.whisperModel ?? "base-en";
      return invoke<boolean>("check_model", { model });
    })
    .then((ok) => setModelState(ok ? "ready" : "missing"))
    .catch(() => setModelState("missing"));

  // Event listeners (unchanged from the original second useEffect)
  const unlisteners = [
    listen<{ text: string; speaker: string }>("transcript", (e) => { /* ... existing ... */ }),
    listen<{ text: string; speaker: string }>("transcript-volatile", (e) => { /* ... existing ... */ }),
    listen<number>("model-download-progress", (e) => { /* ... existing ... */ }),
    listen("model-download-done", () => { /* ... existing ... */ }),
    listen<{ id: string; text: string; kbHits?: any[] }>("suggestion", (e) => { /* ... existing ... */ }),
    listen("suggestion-generating", () => { /* ... existing ... */ }),
  ];

  return () => {
    unlisteners.forEach((p) => p.then((f) => f()));
  };
}, []);
```

Keep all the event listener callback bodies exactly as they are today — only the `check_model` call at the top and the settings load are new.

- [ ] **Step 2: Fix `download_model` call in `handleDownload`**

Find in `App.tsx`:

```typescript
const handleDownload = async () => {
  setModelState("downloading");
  try {
    await invoke("download_model");
  } catch (e) {
    setModelState("missing");
  }
};
```

Replace with:

```typescript
const handleDownload = async () => {
  setModelState("downloading");
  try {
    const model = settings?.whisperModel ?? "base-en";
    await invoke("download_model", { model });
  } catch (e) {
    setModelState("missing");
  }
};
```

- [ ] **Step 3: Pass `isRunning` to `SettingsView`**

Find:

```typescript
{tab === "settings" && <SettingsView />}
```

Replace with:

```typescript
{tab === "settings" && <SettingsView isRunning={isRunning} />}
```

- [ ] **Step 4: Verify TypeScript compiles**

```bash
cd OpenOatsTauri && npx tsc --noEmit
```

Expected: no errors (`SettingsView` already accepts `isRunning` from Task 7).

- [ ] **Step 5: Commit**

```bash
cd ..
git add OpenOatsTauri/src/App.tsx
git commit -m "feat: pass model param to check_model/download_model; pass isRunning to SettingsView"
```

---

## Task 10: Manual smoke test

Run the app and verify all three features work end-to-end.

- [ ] **Step 1: Start the dev server**

```bash
cd OpenOatsTauri && npm run tauri dev
```

- [ ] **Step 2: Verify system audio selector**

- ControlBar shows two dropdowns side by side (mic + system audio)
- System audio dropdown lists Windows output devices
- Selecting a device and restarting the app shows the same device still selected
- Both dropdowns are disabled (greyed out) during recording

- [ ] **Step 3: Verify duplicate mic selector is gone**

- Open Settings → Advanced tab
- "Audio Input" section is absent
- Only "Transcription" section appears (locale + model radio)

- [ ] **Step 4: Verify model radio**

- Settings → Advanced → Transcription shows the radio group
- "English only (base-en)" shows ✓ ready (it was already downloaded)
- "Multilingual (base)" shows "Download ~142 MB" button (not yet downloaded)
- Clicking Download starts the download flow (same progress bar as before)
- After download, "✓ ready" appears on the multilingual option
- Selecting multilingual and starting a recording produces a transcript in the spoken language

- [ ] **Step 5: Final commit (if any last fixes)**

```bash
git add OpenOatsTauri/src-tauri/src/engine.rs \
        OpenOatsTauri/src-tauri/src/audio_windows.rs \
        OpenOatsTauri/src/App.tsx \
        OpenOatsTauri/src/components/ControlBar.tsx \
        OpenOatsTauri/src/components/SettingsView.tsx
git commit -m "fix: smoke test fixes"
```

---

## Summary of all changes

| Layer | What changed |
|---|---|
| `openoats-core/download.rs` | `model_filename` + `model_url` helpers; `download_model` accepts `model: &str` |
| `openoats-core/settings.rs` | New `whisper_model` (default `"base-en"`) and `system_audio_device_name` (default `None`) fields |
| `audio_windows.rs` | `list_render_devices()` + `find_device_by_name()`; `WasapiLoopback::new(device_name)` |
| `engine.rs` | `model_path_for(model)`; updated `check_model(model)`, `download_model(model)`, new `list_sys_audio_devices`; `start_transcription` uses new settings |
| `lib.rs` | `list_sys_audio_devices` registered |
| `Cargo.toml` | `Win32_Devices_Properties` feature added |
| `types.ts` | `systemAudioDeviceName` + `whisperModel` in `AppSettings` |
| `App.tsx` | Fixed call sites for `check_model`/`download_model`; `isRunning` → `SettingsView` |
| `ControlBar.tsx` | System audio `<select>` added |
| `SettingsView.tsx` | Broken mic selector removed; model radio group added; `isRunning` prop accepted |
