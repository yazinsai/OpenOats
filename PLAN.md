# Plan: Add Parakeet STT Provider

## Overview

Add NVIDIA Parakeet (parakeet-tdt-0.6b-v2 / parakeet-tdt-1.1b-v2) as a third local STT provider, following the same Python subprocess worker pattern as `faster-whisper`. Parakeet uses NVIDIA's NeMo ASR framework and delivers state-of-the-art English transcription accuracy on CPU and GPU.

---

## Architecture Summary (matching existing patterns)

```
SttBackend::Parakeet(ParakeetConfig)
    └─ ParakeetWorker (Rust, subprocess manager)
           └─ parakeet_worker.py (Python, NeMo inference)
                    └─ nvidia/parakeet-tdt-0.6b-v2 (HuggingFace model)
```

IPC: line-delimited JSON over stdin/stdout, identical to faster-whisper worker protocol.

---

## Files to Create

### 1. `crates/opencassava-core/src/transcription/parakeet_requirements.txt`
Python dependencies for the Parakeet venv:
```
nemo_toolkit[asr]==2.3.0
```
(NeMo 2.x pulls in PyTorch; the venv will be ~2–4 GB on disk.)

### 2. `crates/opencassava-core/src/transcription/parakeet_worker.py`
Python subprocess worker. Commands:
- `health` → `{"ok": true, "result": {"status": "ready"}}`
- `ensure_model` → loads/caches model; writes stamp file
- `transcribe` → runs `model.transcribe([samples], sample_rate=16000)`; returns `{"ok": true, "result": {"text": "..."}}`
- `shutdown` → exits cleanly

Model cache key: `{model_name}::{device}`. Models dict persists for the lifetime of the subprocess (same as faster-whisper pattern).

### 3. `crates/opencassava-core/src/transcription/parakeet.rs`
Mirrors `faster_whisper.rs` exactly:
- `ParakeetConfig` struct: `runtime_root`, `worker_script_path`, `requirements_path`, `venv_path`, `models_dir`, `model`, `device`
- `ParakeetWorker` struct with `spawn()`, `health()`, `ensure_model()`, `transcribe()`, `shutdown()`
- Top-level functions: `install_runtime()`, `health_check()`, `ensure_model()`, `model_storage_exists()`
- Same setup lock, stderr pump, and `detect_system_python()` helpers (re-uses identical logic)

---

## Files to Modify

### 4. `crates/opencassava-core/src/transcription/mod.rs`
Add one line:
```rust
pub mod parakeet;
```

### 5. `crates/opencassava-core/src/transcription/streaming_transcriber.rs`
Add new enum variant:
```rust
pub enum SttBackend {
    WhisperRs { model_path: String },
    FasterWhisper(crate::transcription::faster_whisper::FasterWhisperConfig),
    Parakeet(crate::transcription::parakeet::ParakeetConfig),  // NEW
    Passthrough,
}
```
Add dispatch arm inside `spawn_blocking`:
```rust
SttBackend::Parakeet(config) => {
    match crate::transcription::parakeet::ParakeetWorker::spawn(&config) {
        Ok(mut worker) => {
            for samples in seg_rx.iter() {
                match worker.transcribe(&samples) {  // no language param (English-only)
                    Ok(text) if !text.is_empty() => { on_progress...; on_final(text); }
                    Ok(_) => { on_progress...; }
                    Err(e) => log::error!("parakeet transcribe error: {e}"),
                }
            }
        }
        Err(e) => log::error!("Failed to launch parakeet worker: {e}"),
    }
}
```
Note: Parakeet is English-only, so `language` is not passed to the worker.

### 6. `crates/opencassava-core/src/settings.rs`
Add two new fields with serde aliases and defaults:
```rust
#[serde(default = "default_parakeet_model", alias = "parakeet_model")]
pub parakeet_model: String,          // default: "nvidia/parakeet-tdt-0.6b-v2"

#[serde(default = "default_parakeet_device", alias = "parakeet_device")]
pub parakeet_device: String,         // default: "auto"
```
Add default fns and update `Default::default()`. Add unit tests covering defaults and round-trip persistence.

### 7. `opencassava/src-tauri/src/engine.rs`
- **Import**: add `parakeet::{self, ParakeetConfig}` and `SttBackend::Parakeet`
- **`AppState::parakeet_root()`**: `persistent_data_dir().join("stt").join("parakeet")`
- **`AppState::parakeet_config(settings)`**: builds `ParakeetConfig` from settings + runtime root
- **`selected_stt_provider()`**: add `"parakeet" => "parakeet"` match arm
- **`resolve_stt_status()`**: add parakeet block (ready/fallback/not-ready variants, analogous to faster-whisper block)
- **`resolve_stt_backend()`**: add `SttBackend::Parakeet(AppState::parakeet_config(settings))` branch
- **`download_stt_model()`**: add parakeet setup flow with `stt-setup-status` events:
  - stage `prepare` → `install_runtime()`
  - stage `health` → `health_check()`
  - stage `model` → `ensure_model()` (downloads model weights)
  - stage `done`

### 8. `opencassava/src/types.ts`
Add two fields to `AppSettings` interface:
```ts
parakeetModel: string;
parakeetDevice: string;
```

### 9. `opencassava/src/components/SettingsView.tsx`
- Add `"parakeet"` entry to `sttProviderOptions` with description
- Add `parakeetModelOptions` array:
  - `nvidia/parakeet-tdt-0.6b-v2` (Recommended — 0.6B, fast, English)
  - `nvidia/parakeet-tdt-1.1b-v2` (Highest accuracy, 1.1B, English)
  - `nvidia/parakeet-ctc-0.6b` (CTC variant, lowest latency)
- Add conditional Parakeet model + device selector UI (visible when `sttProvider === "parakeet"`)
- Add device selector: `auto`, `cpu`, `cuda`
- Extend setup button logic to handle `"parakeet"` provider
- Update model description text for Parakeet (English-only note)

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Python subprocess (not Rust binding) | NeMo has no Rust bindings; consistent with faster-whisper |
| NeMo 2.x (`nemo_toolkit[asr]`) | Official NVIDIA inference path for Parakeet |
| English-only (no `language` param) | Parakeet-TDT is English-only; simplifies API |
| Fallback to whisper-rs | Same graceful degradation as faster-whisper |
| Separate venv at `stt/parakeet/` | Isolation from faster-whisper venv |
| Default model: `parakeet-tdt-0.6b-v2` | Best accuracy/speed trade-off for desktops |

---

## File Change Summary

| File | Action |
|---|---|
| `transcription/parakeet_requirements.txt` | Create |
| `transcription/parakeet_worker.py` | Create |
| `transcription/parakeet.rs` | Create |
| `transcription/mod.rs` | Modify (+1 line) |
| `transcription/streaming_transcriber.rs` | Modify (new enum variant + dispatch arm) |
| `crates/.../settings.rs` | Modify (2 new fields + defaults + tests) |
| `src-tauri/src/engine.rs` | Modify (provider selection, config, status, download) |
| `src/types.ts` | Modify (2 new fields) |
| `src/components/SettingsView.tsx` | Modify (new provider option + Parakeet UI section) |
