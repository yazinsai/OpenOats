# NeMo Speaker Diarization Design

**Date:** 2026-03-24
**Status:** Approved
**Scope:** System audio (Them) stream only — Parakeet STT backend

---

## Overview

Add per-segment speaker diarization to the system audio transcription pipeline using NVIDIA's TitaNet speaker embedding model. Each VAD segment is labeled with a stable speaker ID immediately after transcription. Speaker identity is maintained across segments using an in-memory anchor table with cosine similarity matching.

Diarization is a no-op for Whisper and FasterWhisper backends and degrades gracefully to the existing "Speaker A" fallback if TitaNet errors.

---

## Architecture

```
System audio → VAD → segment
                        ├─ worker.transcribe(samples) → text
                        └─ worker.speaker_id(samples)  → "speaker_0" | "speaker_1" | …
                                                              ↓
                                              participant_label: "Speaker 1" | "Speaker 2" | …
                                                              ↓
                                              TranscriptPayload + SessionRecord
```

---

## Components

### 1. Python Worker (`parakeet_worker.py`)

**New command: `speaker_id`**

- Loads `nvidia/titanet-large` via `nemo_asr.models.EncDecSpeakerLabelModel.from_pretrained()` on first call (downloaded during `ensure_model`, ~80 MB)
- Writes samples to a temp WAV at 16 kHz, extracts a 192-d embedding
- Compares embedding to all entries in `SPEAKER_ANCHORS` dict using cosine similarity
- If best match ≥ threshold (0.7): returns that speaker's stable ID and performs an online anchor update: `anchor = 0.9 * anchor + 0.1 * new_embedding`
- If no match: registers a new anchor entry and returns a new ID (`"speaker_0"`, `"speaker_1"`, …)
- Returns JSON: `{"ok": true, "result": {"speaker_id": "speaker_0"}}`

**New command: `clear_speakers`**

- Resets `SPEAKER_ANCHORS` to `{}`
- Returns `{"ok": true, "result": {"cleared": true}}`

**`ensure_model` update**

- After loading the ASR model, also calls `EncDecSpeakerLabelModel.from_pretrained("nvidia/titanet-large")` so the download happens at install time, not at first recording

**Error handling**

- If TitaNet fails to load, logs a warning and returns `{"ok": false, "error": "..."}` — does not affect ASR

**Module-level state**

```python
SPEAKER_ANCHORS: dict[str, np.ndarray] = {}   # speaker_id → mean embedding
TITANET_MODEL = None                            # loaded lazily, cached
COSINE_THRESHOLD = 0.7
```

---

### 2. Rust `ParakeetWorker` (`parakeet.rs`)

Two new methods following the existing `send_request` pattern:

```rust
pub fn speaker_id(&mut self, samples: &[f32]) -> Result<String, String>
// Returns stable speaker ID, e.g. "speaker_0"

pub fn clear_speakers(&mut self) -> Result<(), String>
```

---

### 3. `StreamingTranscriber` (`streaming_transcriber.rs`)

**`OnFinal` signature change**

```rust
pub type OnFinal = Box<dyn Fn(String, Option<String>) + Send + 'static>;
// (text, speaker_id)
```

`None` for Whisper and FasterWhisper backends. `Some("speaker_0")` for Parakeet when diarization is enabled.

**Parakeet branch update**

After `worker.transcribe(samples)` returns non-empty text:
1. If `diarization_enabled`, call `worker.speaker_id(samples)`
2. On success, pass `Some(speaker_id)` to `on_final`
3. On error, log warning, pass `None`
4. `on_final` always fires — transcription is never blocked by speaker ID failure

**New field**

```rust
pub struct StreamingTranscriber {
    // ...existing fields...
    diarization_enabled: bool,
}
```

Builder method: `.with_diarization(enabled: bool)`.

---

### 4. Engine (`engine.rs`)

**`on_them` closure update**

Receives `(text, speaker_id: Option<String>)`. Maps to participant fields:

| `speaker_id`   | `participant_id` | `participant_label` |
|----------------|-----------------|---------------------|
| `Some("speaker_0")` | `"speaker_0"` | `"Speaker 1"` |
| `Some("speaker_1")` | `"speaker_1"` | `"Speaker 2"` |
| `Some("speaker_N")` | `"speaker_N"` | `"Speaker N+1"` |
| `None`         | `"remote_1"`    | `"Speaker A"` (existing fallback) |

Helper: `fn speaker_id_to_label(id: &str) -> String` — parses the trailing integer from the ID.

**Session start**

At the same point `suggestion_engine.clear()` is called, also call `parakeet_worker.clear_speakers()` on both the mic and sys workers (if taken from the pre-warm pool). This ensures the anchor table resets between sessions.

**`StreamingTranscriber` construction**

Pass `settings.diarization_enabled` to `.with_diarization()` on the Them-stream transcriber. The You-stream transcriber always gets `diarization_enabled: false`.

---

### 5. Settings (`settings.rs` + `AppSettings`)

One new field:

```rust
#[serde(default = "default_true")]
pub diarization_enabled: bool,
```

Default: `true`. The existing `default_true` function covers this.

---

### 6. Frontend (`SettingsView.tsx`)

One new toggle in the Parakeet settings section:

- **Label:** "Speaker diarization"
- **Description:** "Automatically identify different speakers in call audio"
- Visible only when `sttProvider === "parakeet"`
- Bound to `diarization_enabled` setting

No changes to `TranscriptView`, `NotesView`, `SuggestionsView`, or any event schemas — `participant_label` is already rendered and stored correctly.

---

## Data Flow (full path)

1. System audio chunk arrives → VAD accumulates → speech segment fires
2. Segment sent via mpsc channel to blocking Parakeet thread
3. `worker.transcribe(samples)` → `text`
4. If `diarization_enabled`: `worker.speaker_id(samples)` → `"speaker_N"`
5. `on_final(text, Some("speaker_N"))` fires
6. `engine.rs` maps to `participant_label: "Speaker N+1"`
7. `SessionRecord` written with correct participant fields
8. `transcript` event emitted to frontend with `participant_label: "Speaker N+1"`
9. `TranscriptView` renders the label — no logic change required

---

## What Does Not Change

- Session storage format (JSONL) — `participant_id`/`participant_label` fields already exist
- `SuggestionEngine` — filters by `Speaker::Them` regardless of participant label
- Notes generation — uses `display_label()` which already returns `participant_label` when set
- Overlay
- Whisper / FasterWhisper backends — `on_final` second arg is always `None`
- Mic (You) stream — diarization is never applied

---

## Error / Degradation Path

| Failure | Behaviour |
|---------|-----------|
| TitaNet fails to load | Warning logged; `speaker_id` returns error; utterance gets "Speaker A" fallback |
| `speaker_id` errors on a segment | Warning logged; `None` passed to `on_final`; utterance gets fallback |
| Non-Parakeet backend | `diarization_enabled` ignored; all utterances get existing "Speaker A" label |
| `diarization_enabled: false` | `speaker_id` call skipped entirely; existing behaviour preserved |

---

## Out of Scope

- Mic stream diarization (single speaker by definition)
- Post-session re-diarization / label correction
- User-assigned speaker names (renaming "Speaker 1" to "Alice")
- Diarization for Whisper or FasterWhisper backends
- Persisting the anchor table across sessions
