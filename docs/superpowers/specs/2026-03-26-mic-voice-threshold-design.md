# Mic Voice Threshold (Noise Gate) — Design Spec

**Date:** 2026-03-26
**Status:** Approved

---

## Problem

The frequency-domain AEC (PBFDAF) reduces echo at the signal level, but faint residual echo
from the remote speaker leaking into the microphone can still be transcribed. The user observed
that their own speaking voice registers at a noticeably higher RMS than the echo pickup. A
noise gate that silences mic audio below a calibrated voice-level threshold will prevent these
low-level echoes from reaching the transcription engine.

---

## Goals

- Allow the user to calibrate their normal speaking voice level once via a button
- Gate mic audio: chunks whose RMS is below `calibrated_rms × multiplier` are replaced with silence
- Gating applies after AEC output — to both the transcription feed and the level bar
- The threshold multiplier is a persisted, user-configurable value (default 0.6)
- The calibration UI shows a live waveform bar so the user can see their mic level in real time
- No regression when calibration has not been performed (gate defaults to open/disabled)

---

## Data Model

Two new fields in `AppSettings` (`crates/opencassava-core/src/settings.rs`):

```rust
#[serde(default)]
pub mic_calibration_rms: Option<f32>,  // mean top-30% block RMS from calibration; None = gate disabled

#[serde(default = "default_mic_threshold_multiplier")]
pub mic_threshold_multiplier: f32,     // fraction of calibrated RMS used as gate floor; default 0.6
```

Companion default function:
```rust
fn default_mic_threshold_multiplier() -> f32 { 0.6 }
```

Both fields must also be added to the `impl Default for AppSettings` block:
```rust
mic_calibration_rms: None,
mic_threshold_multiplier: default_mic_threshold_multiplier(),
```

Derived threshold at runtime:
```
threshold = mic_calibration_rms.unwrap_or(0.0) * mic_threshold_multiplier
```

If `mic_calibration_rms` is `None`, `threshold` is `0.0` and the gate is open.

**TypeScript (`opencassava/src/types.ts`):** Add to the `AppSettings` interface:
```ts
micCalibrationRms: number | null;
micThresholdMultiplier: number;
```
Without this, the frontend's `save_settings` call would silently drop these fields.

---

## Component Changes

### `crates/opencassava-core/src/audio/echo_cancel.rs` — `MicEchoProcessor`

New field:
```rust
threshold: f32,  // 0.0 = disabled (open gate)
```

New method:
```rust
pub fn set_threshold(&mut self, threshold: f32)
```

**Behavior change in `process_chunk`:**

The gate is independent of whether AEC is enabled. The updated logic:

```rust
pub fn process_chunk(&mut self, mic: &[f32]) -> Vec<f32> {
    if mic.is_empty() { return mic.to_vec(); }

    let cleaned = if self.enabled {
        // ... existing AEC accumulation/processing logic ...
    } else {
        mic.to_vec()
    };

    // Gate: applies regardless of AEC enabled state
    if self.threshold > 0.0 && rms(&cleaned) < self.threshold {
        return vec![0.0; mic.len()];
    }

    cleaned
}
```

Default: `threshold = 0.0` (gate off). Existing behavior is unchanged when threshold is not set.

---

### `opencassava/src-tauri/src/engine.rs`

**`AppState` additions** (two new fields):
```rust
pub preview_task: Mutex<Option<tauri::async_runtime::JoinHandle<()>>>,
pub preview_stop: Arc<std::sync::atomic::AtomicBool>,
```

Initialize in `AppState::new()`:
```rust
preview_task: Mutex::new(None),
preview_stop: Arc::new(std::sync::atomic::AtomicBool::new(false)),
```

**At session start** (`start_recording` / `start_transcription`):
```rust
let threshold = settings.mic_calibration_rms.unwrap_or(0.0) * settings.mic_threshold_multiplier;
echo_processor.set_threshold(threshold);
```

---

#### New Tauri command: `start_calibration_preview`

```rust
#[tauri::command]
pub async fn start_calibration_preview(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String>
```

- Returns an error if a recording session is already active (`state.is_running` is true) — in that case the frontend should instead listen to the existing `audio-level` event's `you` field
- Resets `state.preview_stop` to `false`
- Spawns a task that opens `CpalMicCapture` on the currently selected device, emits `calibration-audio-level` events every 100ms, and exits when `preview_stop` is set to `true`
- Stores the task handle in `state.preview_task`

**Calibration-audio-level event payload** (new struct in `engine.rs`):
```rust
#[derive(Clone, Serialize)]
pub struct CalibrationAudioLevelPayload {
    pub level: f32,
}
```
Event name: `"calibration-audio-level"`. Emitted every 100ms with the current mic RMS.

---

#### New Tauri command: `stop_calibration_preview`

```rust
#[tauri::command]
pub async fn stop_calibration_preview(
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<(), String>
```

- Sets `state.preview_stop` to `true`
- Awaits / drops the task handle from `state.preview_task`

---

#### New Tauri command: `calibrate_mic_threshold`

```rust
#[tauri::command]
pub async fn calibrate_mic_threshold(
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<f32, String>
```

- Returns an error string if `state.is_running` is true (active recording session)
- **Reuses the running preview stream** rather than opening a second `CpalMicCapture`. The preview task collects block RMSes into a shared `Arc<Mutex<Vec<f32>>>`. After 3 seconds, `calibrate_mic_threshold` reads from that buffer, computes the top-30% mean, saves it to settings, and returns it.
- Alternatively (simpler if preview is already stopped): stop the preview, open a fresh capture, collect 3 seconds, close it. Either strategy is acceptable; the important constraint is that **only one `CpalMicCapture` is open at a time**.
- Saves `settings.mic_calibration_rms = Some(rms_value)` and calls `settings.save()`
- Returns `Err("Level too low — check your microphone".into())` if the computed RMS is < 0.001

**Top-30% mean extracted as a pure function** (for unit testing):
```rust
fn top_percentile_mean(block_rmses: &[f32], percentile: f32) -> f32 {
    // sort descending, take top `percentile` fraction, compute mean
}
```

---

### Command Registration (`opencassava/src-tauri/src/lib.rs`)

Add to the `invoke_handler!` macro:
```
calibrate_mic_threshold,
start_calibration_preview,
stop_calibration_preview,
```

---

### Settings UI (`opencassava/src/components/Settings.tsx` or equivalent)

New **Mic Voice Threshold** section, placed below the echo cancellation toggle:

**When not calibrated (`micCalibrationRms === null`):**
- Text: "Not calibrated — gate is disabled"
- "Calibrate" button

**Calibration flow (on button click):**
1. Call `start_calibration_preview`
2. Show live `WaveformVisualizer` bar driven by `calibration-audio-level` events (`e.payload.level`)
3. Display countdown: "Speak normally… 3 / 2 / 1"
4. After 3 seconds, call `calibrate_mic_threshold`; call `stop_calibration_preview`
5. Display result: "Calibrated: [rms × 1000 rounded to 1 decimal]" (e.g. "Calibrated: 43.2" on a 0–1000 scale) or 3 decimal places of the raw float — either is acceptable; pick whichever is more readable in context

**When calibrated:**
- Shows current calibrated value
- "Recalibrate" button (reruns the flow above)
- **Sensitivity** input: numeric input or small slider, range **0.1–0.8**, step 0.05, default 0.6
  - Upper bound is 0.8 (not 1.0) to prevent the user from accidentally silencing their own voice
  - Updates `micThresholdMultiplier` in settings on change
- Helper text: "Audio below this level will be silenced. Recalibrate if you change microphones."

The existing `WaveformVisualizer` component is reused as-is (`level` prop = the `level` field from the event payload).

---

## Gate Behavior When AEC Is Disabled

The noise gate is **independent** of `echo_cancellation_enabled`. When AEC is disabled, `process_chunk` returns the raw mic audio; the gate check then runs on that raw audio and silences it if below threshold. This ensures the gate works even for users who turn off AEC.

---

## Settings Defaults

| Field | Default | Notes |
|---|---|---|
| `mic_calibration_rms` | `None` | Gate disabled until calibrated |
| `mic_threshold_multiplier` | `0.6` | 60% of speaking level; UI range 0.1–0.8 |

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Mic device unavailable during calibration | Return error string; show inline in Settings UI |
| Calibration RMS < 0.001 (mic muted/silent) | Return error: "Level too low — check your microphone" |
| `calibrate_mic_threshold` called during active session | Return error: "Cannot calibrate during an active recording" |
| `start_calibration_preview` called during active session | Return error; frontend falls back to `audio-level` events |
| `stop_calibration_preview` called when no preview running | No-op, return Ok |

---

## Testing

- Unit test: `top_percentile_mean` pure function with known inputs
- Unit test: `MicEchoProcessor` with threshold set — a chunk with RMS below threshold returns all-zeros
- Unit test: threshold = 0.0 — all audio passes through unchanged
- Unit test: gate applies when AEC is disabled (`set_enabled(false)`, `set_threshold(0.05)`) — low-RMS chunk is silenced
- Manual: calibrate with normal speech, confirm echo from speaker is silenced in a subsequent recording session
