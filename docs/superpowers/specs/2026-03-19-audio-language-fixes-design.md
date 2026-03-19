# Design: Audio Device Selection, Duplicate Removal & Language Model Fix

**Date:** 2026-03-19
**Status:** In Review (revision 2)

---

## Problem Summary

Three related issues in the OpenOats Tauri app:

1. **System audio not selectable** — WASAPI loopback capture runs automatically as the "them" track but always uses the default render device. There is no UI to choose a different output device to loop back from.
2. **Duplicate mic selector** — A microphone dropdown exists in both `ControlBar.tsx` (working, populates device list) and `SettingsView.tsx` > Advanced > Audio Input (broken, never populates device list, always shows "System Default" only).
3. **Language selector has no effect** — The transcription locale is saved and passed to Whisper correctly, but the downloaded model is `ggml-base.en.bin` — the English-only variant — which ignores the language parameter entirely.

---

## Decisions

- System audio: add a device dropdown in `ControlBar` (mirrors mic selector pattern, visible and quick to change before recording).
- Duplicate mic selector: remove the broken one from `SettingsView` entirely.
- Language model: keep both models (`base-en` and `base`), add an explicit user-facing toggle in Settings > Advanced > Transcription. Default stays `base-en` to preserve existing behaviour. Old model files are **never auto-deleted** (see Out of Scope).

---

## Data Model Changes

### `AppSettings` — two new fields

| Field | Type | Default | Description |
|---|---|---|---|
| `systemAudioDeviceName` | `Option<String>` / `string \| null` | `null` | Selected loopback device. `null` = system default. |
| `whisperModel` | `String` / `string` | `"base-en"` | `"base-en"` or `"base"`. Controls which model file is used. |

Both new fields must be handled carefully on the Rust side:

- `systemAudioDeviceName: Option<String>` — use `#[serde(default)]`. `Option<String>` derives `Default` as `None`, which matches the intended default.
- `whisperModel: String` — **do NOT use plain `#[serde(default)]`**. `String::default()` is `""`, not `"base-en"`. Use `#[serde(default = "default_whisper_model")]` with a named function:

  ```rust
  fn default_whisper_model() -> String { "base-en".to_string() }
  ```

  This ensures existing settings files without this key deserialize to `"base-en"` correctly.

### Model filenames

| Setting value | Filename | Notes |
|---|---|---|
| `"base-en"` | `ggml-base.en.bin` | English-only, existing behaviour |
| `"base"` | `ggml-base.bin` | Multilingual Whisper base model (~142 MB) |

Both files live in the app data directory. Only the selected model needs to be present to record; the other may or may not exist.

---

## Backend Changes

### New Tauri command: `list_sys_audio_devices`

```
list_sys_audio_devices() -> Vec<String>
```

- **Windows:** enumerates WASAPI render endpoints via `IMMDeviceEnumerator::EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)`, returns friendly names.
- **macOS:** macOS system audio enumeration is **deferred / out of scope** for this change. The function returns an empty `Vec` on macOS, so the selector shows only "System Default" on that platform.
- **Other:** returns empty vec.
- Must be annotated with `#[tauri::command]`, declared in `engine.rs`, and registered in the `invoke_handler!` macro in `lib.rs`.

### Updated Tauri command: `check_model(model: String) -> Result<bool, String>`

The existing `check_model` command is updated to accept an explicit `model` parameter (`"base-en"` or `"base"`). It resolves the filename via `model_filename(model)` and checks existence. This replaces the current no-argument version.

**Existing call sites to update** — there are two in `App.tsx`:
- Line ~46: `invoke<boolean>("check_model")` — on-boot model check. Update to pass the current `whisperModel` setting. Since settings may not yet be loaded at this point, read settings first (already done via `get_settings` in the same effect) and pass `settings.whisperModel ?? "base-en"`.
- The `SettingsView` on-mount calls described below are new additions, not updates to existing calls.

The frontend calls it once per model variant in `SettingsView` on mount to populate badge state for both radio options independently.

### Updated Tauri command: `download_model(model: String) -> Result<(), String>`

The existing `download_model` command gains an explicit `model` parameter. It resolves the target filename via `model_filename(model)` and downloads only that file.

**Existing call site to update** — one in `App.tsx`:
- Line ~119: `invoke("download_model")` — triggered by the "Download Model" button on the missing-model screen. Update to pass the currently selected `settings.whisperModel ?? "base-en"`. The current hardcoded `MODEL_URL` constant in `download.rs` becomes a function of the model variant:

| Model | URL |
|---|---|
| `"base-en"` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin` |
| `"base"` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin` |

Both URLs are from the canonical `ggerganov/whisper.cpp` Hugging Face repository. This replaces the current no-argument version.

### Model filename helper

The helper lives in `openoats-core/src/download.rs` as a `pub fn` so both `download.rs` internally and `engine.rs` (via `openoats_core::download::model_filename`) can call it:

```rust
pub fn model_filename(whisper_model: &str) -> &'static str {
    match whisper_model {
        "base" => "ggml-base.bin",
        _ => "ggml-base.en.bin",  // default / "base-en"
    }
}
```

`check_model` (in `engine.rs`) and `download_model` (in `download.rs`) both call this helper with their `model` argument.

### `SystemAudioCapture` — optional device selection

`WasapiLoopback::new()` gains a `device_name: Option<&str>` parameter:
- `Some(name)`: enumerate render endpoints, find the one with matching friendly name, use it for loopback capture.
- `None`: fall back to `GetDefaultAudioEndpoint` (existing behaviour, no regression).

### `start_transcription` — reads `systemAudioDeviceName` and `whisperModel`

Reads `settings.system_audio_device_name` and passes it to `SystemAudioCapture::new()`, following the same pattern as `input_device_name` for mic selection.

Reads `settings.whisper_model` to resolve the model path for both the mic and system audio `StreamingTranscriber` instances.

---

## Frontend Changes

### `ControlBar.tsx` — system audio device selector

A second `<select>` is added immediately after the mic selector. `ControlBar` already receives `isRunning` as an existing prop — no new props are needed for this component:

- On mount: calls `invoke<AppSettings>("get_settings")` to read `systemAudioDeviceName` and initialise `selectedSysDevice` state. The reverse mapping applies here: a `null` value from settings is mapped to `"default"` so the dropdown renders the correct first option. Also calls `invoke<string[]>("list_sys_audio_devices")` to populate the option list.
- First option: `"System Default"` (value `"default"`).
- Disabled while `isRunning` (same as mic selector).
- `onChange`: the `"default"` option value is mapped to `null` before being written to `systemAudioDeviceName` — matching the `Option<String>` backend representation where `None` means system default. All other option values are written as-is. Reads current settings from the backend via `get_settings`, merges `systemAudioDeviceName: value === "default" ? null : value`, and writes via `save_settings`. **To avoid a read-modify-write race between the two dropdowns**, the system audio selector uses the same sequential `get_settings` + `save_settings` pattern already used by the mic selector. This is a known minor race under rapid simultaneous changes; it is accepted as a low-risk limitation given that both selectors are disabled during recording.
- If `list_sys_audio_devices` returns an empty list (macOS or failure), only "System Default" is shown — graceful degradation.

### `SettingsView.tsx` — remove duplicate mic selector

Delete the entire "Audio Input" `<div>` section (the one with the `<h4>` heading "Audio Input") from the Advanced tab. No replacement — the canonical control is in `ControlBar`.

### `SettingsView.tsx` — model selector in Transcription section (whisperModel radio)

Added below the locale input in Advanced > Transcription. `SettingsView` currently takes no props; it gains one new prop: `isRunning: boolean`, passed from `App.tsx` where the state already exists. The radio group is **disabled while `isRunning`**.

```
Whisper Model
  ● English only (base-en)   [✓ ready]
  ○ Multilingual (base)       [Download ~142 MB]
```

- Two radio inputs bound to `settings.whisperModel`.
- On mount: calls `check_model("base-en")` and `check_model("base")` in parallel to determine which files exist, and stores results in local state (`baseEnReady`, `baseReady`).
- Each option shows a `✓ ready` badge if its corresponding file exists, or a `Download` button if not.
- Clicking a Download button calls `download_model(model)` with the relevant variant. On completion (resolved promise), the component calls `check_model(model)` to re-verify the file exists before setting the badge to ready — this guards against silent download failures.
- Selecting a radio that is already downloaded saves `whisperModel` immediately via `save_settings`. The change takes effect on the next recording start.
- Selecting a radio whose model is not yet downloaded: saves the preference but also shows the Download button — does **not** auto-start a download.
- The radio group is visually disabled (pointer-events: none, reduced opacity) when `isRunning`.

### `types.ts`

Add to `AppSettings`:

```typescript
systemAudioDeviceName: string | null;
whisperModel: string;
```

---

## Error Handling

- If `list_sys_audio_devices` fails, the system audio selector shows only "System Default" — no crash.
- If the selected system audio device is unavailable at capture time, `buffer_stream()` logs a warning and returns an empty stream — the "them" track produces no audio but the app continues.
- If `whisperModel` is an unrecognised value, the backend `model_filename` helper defaults to `base-en`.
- If a model file is missing when recording starts, `start_transcription` returns an error. The error message should include the missing filename (e.g., `"Whisper model not found: ggml-base.bin. Download it in Settings > Advanced > Transcription."`) so the user knows how to recover. This is a minor improvement over the existing generic message.

---

## Out of Scope

- macOS system audio device enumeration (deferred; the selector shows only "System Default" on macOS).
- Auto-deleting old model files when the user switches models. Both files may coexist on disk indefinitely. Storage cleanup is the user's responsibility.
- Selecting per-channel sample rate or bit depth.
- Showing real-time audio level for the system audio device in the selector.
- Auto-switching models based on locale.
