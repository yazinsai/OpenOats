# NeMo TitaNet Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-segment speaker identification to the system audio (Them) stream using NeMo's TitaNet model, so multiple remote participants get distinct "Speaker 1", "Speaker 2" labels instead of a hardcoded "Speaker A".

**Architecture:** Each VAD speech segment that the Parakeet worker transcribes is also passed to TitaNet to extract a speaker embedding, which is compared against an in-memory anchor table using cosine similarity. Stable speaker IDs (`speaker_0`, `speaker_1`, …) are returned from Python, mapped to display labels in Rust, and stored as `participant_label` on every utterance — using the fields that already exist in the data model.

**Tech Stack:** Rust (Tauri/tokio), Python (NeMo `nvidia/titanet-large`), React/TypeScript frontend. Tests: `cargo test`, Python `pytest`.

**Spec:** `docs/superpowers/specs/2026-03-24-nemo-diarization-design.md`

---

## File Map

| File | Change |
|------|--------|
| `crates/opencassava-core/src/settings.rs` | Add `diarization_enabled: bool` field |
| `opencassava/src/types.ts` | Add `diarization_enabled: boolean` to `AppSettings` interface |
| `crates/opencassava-core/src/transcription/parakeet.rs` | Add `diarization_enabled` to `ParakeetConfig`; update `ensure_model` free-fn + method; add `speaker_id`, `clear_speakers` methods |
| `crates/opencassava-core/src/transcription/parakeet_worker.py` | Add `speaker_id`, `clear_speakers` commands; update `ensure_model` |
| `crates/opencassava-core/src/transcription/streaming_transcriber.rs` | Change `OnFinal` type; add `diarization_enabled` + `clear_speakers_on_start` fields; update Parakeet branch |
| `opencassava/src-tauri/src/engine.rs` | Add `speaker_id_to_label` helper; update `on_them`/`on_you` closures; wire builder methods |
| `opencassava/src/components/SettingsView.tsx` | Add speaker diarization toggle in Parakeet section |

---

## Task 1: Add `diarization_enabled` to Rust settings

**Files:**
- Modify: `crates/opencassava-core/src/settings.rs`

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` block in `settings.rs` (after the last existing test):

```rust
#[test]
fn diarization_enabled_defaults_to_true() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("nonexistent.json");
    let s = AppSettings::load_from(path);
    assert!(s.diarization_enabled);
}

#[test]
fn diarization_enabled_persists_and_reloads() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("settings.json");
    let mut s = AppSettings::load_from(path.clone());
    s.diarization_enabled = false;
    s.save_to(path.clone());
    let s2 = AppSettings::load_from(path);
    assert!(!s2.diarization_enabled);
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml diarization_enabled 2>&1
```

Expected: compile error — field `diarization_enabled` does not exist on `AppSettings`.

- [ ] **Step 3: Add field to `AppSettings` struct** (after `smart_question_system_prompt`):

```rust
#[serde(default = "default_true")]
pub diarization_enabled: bool,
```

- [ ] **Step 4: Add to `impl Default for AppSettings`** (the explicit struct literal, after `smart_question_system_prompt: default_smart_question_system_prompt()`):

```rust
diarization_enabled: default_true(),
```

- [ ] **Step 5: Run tests — confirm they pass**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml diarization_enabled 2>&1
```

Expected: 2 tests pass.

- [ ] **Step 6: Confirm full crate still compiles**

```bash
cargo check --manifest-path crates/opencassava-core/Cargo.toml 2>&1
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add crates/opencassava-core/src/settings.rs
git commit -m "feat: add diarization_enabled setting (default true)"
```

---

## Task 2: Add `diarization_enabled` to TypeScript `AppSettings`

**Files:**
- Modify: `opencassava/src/types.ts`

- [ ] **Step 1: Add field to the `AppSettings` interface** (after `parakeetDevice: string;`):

```typescript
diarizationEnabled: boolean;
```

- [ ] **Step 2: Confirm TypeScript compiles**

```bash
cd opencassava && npm run build 2>&1 | tail -20
```

Expected: build succeeds (or same pre-existing errors as before — no new errors).

- [ ] **Step 3: Commit**

```bash
git add opencassava/src/types.ts
git commit -m "feat: add diarizationEnabled to TypeScript AppSettings type"
```

---

## Task 3: Add `diarization_enabled` to `ParakeetConfig` and wire into engine

**Files:**
- Modify: `crates/opencassava-core/src/transcription/parakeet.rs`
- Modify: `opencassava/src-tauri/src/engine.rs`

- [ ] **Step 1: Add field to `ParakeetConfig` struct** in `parakeet.rs` (after `pub language: String`):

```rust
/// Controls whether TitaNet speaker embedding model is downloaded and used.
pub diarization_enabled: bool,
```

- [ ] **Step 2: Set field in `AppState::parakeet_config()`** in `engine.rs` (after `language: settings.transcription_locale.clone()`):

```rust
diarization_enabled: settings.diarization_enabled,
```

- [ ] **Step 3: Confirm compilation**

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors. (The field is added to the struct and set in the one place it's constructed.)

- [ ] **Step 4: Commit**

```bash
git add crates/opencassava-core/src/transcription/parakeet.rs opencassava/src-tauri/src/engine.rs
git commit -m "feat: add diarization_enabled to ParakeetConfig"
```

---

## Task 4: Python worker — `clear_speakers` command

**Files:**
- Modify: `crates/opencassava-core/src/transcription/parakeet_worker.py`

- [ ] **Step 1: Add module-level diarization state** near the top of `parakeet_worker.py`, after the `MODELS = {}` line:

```python
SPEAKER_ANCHORS = {}        # speaker_id (str) → mean embedding (np.ndarray)
SPEAKER_COUNTER = 0         # next speaker index
TITANET_MODEL = None
COSINE_THRESHOLD = 0.7
MIN_SPEAKER_ID_SAMPLES = 16_000  # 1.0 s at 16 kHz
```

- [ ] **Step 2: Add `handle_clear_speakers` function** after `handle_ensure_model`:

```python
def handle_clear_speakers():
    global SPEAKER_ANCHORS, SPEAKER_COUNTER
    SPEAKER_ANCHORS.clear()
    SPEAKER_COUNTER = 0
    emit({"ok": True, "result": {"cleared": True}})
```

- [ ] **Step 3: Wire into `main()` dispatch** (inside the `if command == ...` chain, after `elif command == "ensure_model":`):

```python
elif command == "clear_speakers":
    handle_clear_speakers()
```

- [ ] **Step 4: Write and run a quick inline smoke test**

Create a temporary file `test_clear_speakers.py` alongside the worker (do not commit):

```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

# Monkey-patch emit so we can capture output
import parakeet_worker as pw
results = []
pw.emit = lambda p: results.append(p)

# Seed some state
import numpy as np
pw.SPEAKER_ANCHORS["speaker_0"] = np.array([1.0, 0.0])
pw.SPEAKER_COUNTER = 1

pw.handle_clear_speakers()

assert pw.SPEAKER_ANCHORS == {}, f"Expected empty, got {pw.SPEAKER_ANCHORS}"
assert pw.SPEAKER_COUNTER == 0, f"Expected 0, got {pw.SPEAKER_COUNTER}"
assert results[0] == {"ok": True, "result": {"cleared": True}}
print("PASS")
```

Run with the Parakeet venv Python (only if venv is installed; otherwise skip to Step 5):

```bash
# Adjust path to actual venv location from AppState::parakeet_root()
# Typically: %APPDATA%\OpenCassava\stt\parakeet\venv\Scripts\python.exe on Windows
# If not installed yet, skip this step — the change will be tested during integration
```

- [ ] **Step 5: Delete the test file**

```bash
rm crates/opencassava-core/src/transcription/test_clear_speakers.py 2>/dev/null; true
```

- [ ] **Step 6: Commit**

```bash
git add crates/opencassava-core/src/transcription/parakeet_worker.py
git commit -m "feat: add clear_speakers command to parakeet worker"
```

---

## Task 5: Python worker — `speaker_id` command

**Files:**
- Modify: `crates/opencassava-core/src/transcription/parakeet_worker.py`

- [ ] **Step 1: Add `cosine_similarity` helper** and `load_titanet` helper after the `load_model` function:

```python
def cosine_similarity(a, b):
    import numpy as np
    denom = (np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def load_titanet():
    global TITANET_MODEL
    if TITANET_MODEL is not None:
        return TITANET_MODEL
    import nemo.collections.asr as nemo_asr
    TITANET_MODEL = nemo_asr.models.EncDecSpeakerLabelModel.from_pretrained("nvidia/titanet-large")
    TITANET_MODEL.eval()
    return TITANET_MODEL
```

- [ ] **Step 2: Add `handle_speaker_id` function** after `handle_clear_speakers`:

```python
def handle_speaker_id(payload):
    global SPEAKER_ANCHORS, SPEAKER_COUNTER
    import numpy as np

    samples = np.asarray(payload.get("samples", []), dtype=np.float32)
    if len(samples) < MIN_SPEAKER_ID_SAMPLES:
        emit({"ok": True, "result": {"speaker_id": None}})
        return

    try:
        model = load_titanet()
    except Exception as exc:
        emit({"ok": False, "error": f"TitaNet load failed: {exc}"})
        return

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
        sf.write(tmp_path, samples, 16000)
        embedding = model.get_embedding(tmp_path)
        if hasattr(embedding, "cpu"):
            embedding = embedding.cpu().numpy()
        embedding = np.asarray(embedding, dtype=np.float32).flatten()
    except Exception as exc:
        emit({"ok": False, "error": f"Embedding extraction failed: {exc}"})
        return
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)

    # Match against existing anchors
    best_id = None
    best_score = -1.0
    for sid, anchor in SPEAKER_ANCHORS.items():
        score = cosine_similarity(embedding, anchor)
        if score > best_score:
            best_score = score
            best_id = sid

    if best_id is not None and best_score >= COSINE_THRESHOLD:
        # Update anchor with exponential moving average
        SPEAKER_ANCHORS[best_id] = 0.9 * SPEAKER_ANCHORS[best_id] + 0.1 * embedding
        emit({"ok": True, "result": {"speaker_id": best_id}})
    else:
        new_id = f"speaker_{SPEAKER_COUNTER}"
        SPEAKER_COUNTER += 1
        SPEAKER_ANCHORS[new_id] = embedding
        emit({"ok": True, "result": {"speaker_id": new_id}})
```

- [ ] **Step 3: Wire into `main()` dispatch** (after `elif command == "clear_speakers":`):

```python
elif command == "speaker_id":
    handle_speaker_id(payload)
```

- [ ] **Step 4: Write and run tests that exercise `handle_speaker_id` end-to-end**

Create temporary `test_speaker_id.py` (do not commit). The tests mock TitaNet so they run without GPU/NeMo and actually call `handle_speaker_id` to guard against control-flow bugs:

```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np
import parakeet_worker as pw

# Override emit to capture output
results = []
pw.emit = lambda p: results.append(p)

# ── Test helpers ──────────────────────────────────────────────────────────────

def make_fake_embedding(vec):
    """Returns a mock TitaNet model that always returns `vec`."""
    class FakeModel:
        def get_embedding(self, path):
            return np.array(vec, dtype=np.float32)
        def eval(self): return self
    return FakeModel()

# ── Test 1: short segment returns null without calling TitaNet ────────────────
results.clear()
pw.SPEAKER_ANCHORS.clear()
pw.SPEAKER_COUNTER = 0
pw.TITANET_MODEL = None
called_titanet = []

original_load = pw.load_titanet
pw.load_titanet = lambda: called_titanet.append(True) or original_load()
pw.handle_speaker_id({"samples": [0.0] * 100})  # 100 < 16_000
pw.load_titanet = original_load

assert results[0] == {"ok": True, "result": {"speaker_id": None}}, results[0]
assert len(called_titanet) == 0, "TitaNet should not be called for short segment"
print("PASS: short segment skips TitaNet")

# ── Test 2: new speaker creates anchor at speaker_0, counter increments ───────
results.clear()
pw.SPEAKER_ANCHORS.clear()
pw.SPEAKER_COUNTER = 0
pw.TITANET_MODEL = make_fake_embedding([1.0, 0.0, 0.0])

# Samples long enough (16000 floats)
pw.handle_speaker_id({"samples": [0.1] * 16_000})

assert pw.SPEAKER_COUNTER == 1
assert "speaker_0" in pw.SPEAKER_ANCHORS
assert results[0] == {"ok": True, "result": {"speaker_id": "speaker_0"}}, results[0]
print("PASS: new speaker creates anchor_0")

# ── Test 3: same speaker matches existing anchor ──────────────────────────────
results.clear()
# SPEAKER_ANCHORS already has speaker_0 = [1,0,0]; use identical embedding → score=1.0
pw.handle_speaker_id({"samples": [0.1] * 16_000})

assert pw.SPEAKER_COUNTER == 1, "Counter must NOT increment on match"
assert results[0] == {"ok": True, "result": {"speaker_id": "speaker_0"}}, results[0]
print("PASS: same speaker matches existing anchor")

# ── Test 4: different speaker creates new anchor ──────────────────────────────
results.clear()
pw.TITANET_MODEL = make_fake_embedding([0.0, 1.0, 0.0])  # orthogonal → no match
pw.handle_speaker_id({"samples": [0.1] * 16_000})

assert pw.SPEAKER_COUNTER == 2
assert "speaker_1" in pw.SPEAKER_ANCHORS
assert results[0] == {"ok": True, "result": {"speaker_id": "speaker_1"}}, results[0]
print("PASS: different speaker creates anchor_1")

# ── Test 5: cosine_similarity correctness ─────────────────────────────────────
a = np.array([1.0, 0.0, 0.0])
assert abs(pw.cosine_similarity(a, a) - 1.0) < 1e-6
b = np.array([0.0, 1.0, 0.0])
assert abs(pw.cosine_similarity(a, b)) < 1e-6
print("PASS: cosine_similarity")

# ── Test 6: clear_speakers resets counter AND anchors ────────────────────────
results.clear()
pw.handle_clear_speakers()
assert pw.SPEAKER_COUNTER == 0
assert pw.SPEAKER_ANCHORS == {}
assert results[0]["result"]["cleared"] is True
print("PASS: clear_speakers resets state")

print("\nAll tests passed.")
```

Run (skip if numpy not available in the current environment):

```bash
python crates/opencassava-core/src/transcription/test_speaker_id.py 2>&1
```

Expected: `All tests passed.`

- [ ] **Step 5: Delete test file**

```bash
rm crates/opencassava-core/src/transcription/test_speaker_id.py 2>/dev/null; true
```

- [ ] **Step 6: Commit**

```bash
git add crates/opencassava-core/src/transcription/parakeet_worker.py
git commit -m "feat: add speaker_id command with TitaNet embeddings and anchor table"
```

---

## Task 6: Python worker — update `ensure_model` for TitaNet download

**Files:**
- Modify: `crates/opencassava-core/src/transcription/parakeet_worker.py`

- [ ] **Step 1: Update `handle_ensure_model`** — after the `load_model(model_name, device)` call, add conditional TitaNet pre-load:

The current function body is:
```python
def handle_ensure_model(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    load_model(model_name, device)
    emit({"ok": True, "result": {"model": model_name}})
```

Replace it with:
```python
def handle_ensure_model(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    load_model(model_name, device)
    if payload.get("diarization_enabled", False):
        try:
            load_titanet()
        except Exception as exc:
            # Log but don't fail — ASR still works without TitaNet
            import sys
            print(f"[parakeet] Warning: TitaNet pre-load failed: {exc}", file=sys.stderr)
    emit({"ok": True, "result": {"model": model_name}})
```

- [ ] **Step 2: Confirm Python syntax is valid**

```bash
python -c "import ast; ast.parse(open('crates/opencassava-core/src/transcription/parakeet_worker.py').read()); print('syntax ok')"
```

Expected: `syntax ok`

- [ ] **Step 3: Commit**

```bash
git add crates/opencassava-core/src/transcription/parakeet_worker.py
git commit -m "feat: pre-load TitaNet during ensure_model when diarization enabled"
```

---

## Task 7: Rust `ParakeetWorker` — new methods and updated `ensure_model`

**Files:**
- Modify: `crates/opencassava-core/src/transcription/parakeet.rs`

- [ ] **Step 1: Write a failing test for `speaker_id`** at the bottom of `parakeet.rs`.

`parakeet.rs` has **no existing `#[cfg(test)]` block** — create one from scratch. The first test is a compile-time guard: it references `ParakeetWorker::speaker_id` and won't compile until the method exists. The two JSON parsing tests exercise the result extraction logic and pass independently (they work on plain `serde_json::Value`, no worker needed). The compile-guard is what makes Step 2 fail.

Key detail: `send_request` returns `json["result"]` already, so the `speaker_id()` method receives the result object directly and indexes `response["speaker_id"]` — not `response["result"]["speaker_id"]`.

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speaker_id_method_exists() {
        // Compile-time guard: won't compile until speaker_id is added to ParakeetWorker
        // with the correct signature. The test itself is a no-op at runtime.
        let _: fn(&mut ParakeetWorker, &[f32]) -> Result<Option<String>, String> =
            ParakeetWorker::speaker_id;
    }

    #[test]
    fn speaker_id_parses_none_from_result_object() {
        // send_request returns json["result"] already.
        // Python sends {"speaker_id": null} for short segments.
        let result_obj: serde_json::Value =
            serde_json::from_str(r#"{"speaker_id":null}"#).unwrap();
        let speaker_id: Option<String> = result_obj["speaker_id"]
            .as_str()
            .map(|s| s.to_string());
        assert!(speaker_id.is_none());
    }

    #[test]
    fn speaker_id_parses_some_from_result_object() {
        // Python sends {"speaker_id": "speaker_0"} on a match.
        let result_obj: serde_json::Value =
            serde_json::from_str(r#"{"speaker_id":"speaker_0"}"#).unwrap();
        let speaker_id: Option<String> = result_obj["speaker_id"]
            .as_str()
            .map(|s| s.to_string());
        assert_eq!(speaker_id, Some("speaker_0".to_string()));
    }
}
```

- [ ] **Step 2: Run tests — confirm they FAIL (compile error)**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml speaker_id 2>&1
```

Expected: compile error — `no method named speaker_id found for mutable reference &mut ParakeetWorker`. This is the TDD red state.

- [ ] **Step 3: Update `ParakeetWorker::ensure_model` method signature** in `parakeet.rs`. Find the current method:

```rust
pub fn ensure_model(&mut self) -> Result<(), String> {
    self.send_request(json!({
        "command": "ensure_model",
        "model": self.config.model.clone(),
        "device": self.config.device.clone(),
    }))?;
    Ok(())
}
```

Replace with:

```rust
pub fn ensure_model(&mut self, diarization_enabled: bool) -> Result<(), String> {
    self.send_request(json!({
        "command": "ensure_model",
        "model": self.config.model.clone(),
        "device": self.config.device.clone(),
        "diarization_enabled": diarization_enabled,
    }))?;
    Ok(())
}
```

- [ ] **Step 4: Update the free function `ensure_model`** call site (line ~134). Change:

```rust
worker.ensure_model()?;
```

to:

```rust
worker.ensure_model(config.diarization_enabled)?;
```

- [ ] **Step 5: Add `clear_speakers` method** to `ParakeetWorker` (after `ensure_model`):

```rust
pub fn clear_speakers(&mut self) -> Result<(), String> {
    self.send_request(json!({ "command": "clear_speakers" }))?;
    Ok(())
}
```

- [ ] **Step 6: Add `speaker_id` method** to `ParakeetWorker` (after `clear_speakers`):

```rust
/// Returns the stable speaker ID for this audio segment, or None if the segment
/// was too short to embed reliably. Errors if the worker fails.
pub fn speaker_id(&mut self, samples: &[f32]) -> Result<Option<String>, String> {
    let response = self.send_request(json!({
        "command": "speaker_id",
        "samples": samples,
        "model": self.config.model.clone(),
        "device": self.config.device.clone(),
    }))?;
    // Python returns {"speaker_id": "speaker_N"} or {"speaker_id": null}
    Ok(response["speaker_id"].as_str().map(|s| s.to_string()))
}
```

- [ ] **Step 7: Confirm everything compiles**

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors.

Note: `health_check` in `parakeet.rs` calls `worker.health()`, **not** `worker.ensure_model()` — no update needed there. The only two `ensure_model()` call sites are (1) the free function `ensure_model` (updated in Step 4) and (2) `streaming_transcriber.rs` (updated in Task 10). No other sites exist.

- [ ] **Step 8: Commit**

```bash
git add crates/opencassava-core/src/transcription/parakeet.rs
git commit -m "feat: add speaker_id, clear_speakers methods and update ensure_model signature"
```

---

## Task 8: `StreamingTranscriber` — new fields and builder methods

**Files:**
- Modify: `crates/opencassava-core/src/transcription/streaming_transcriber.rs`

Note: This task adds the fields only. The `OnFinal` type change and Parakeet branch logic come in Tasks 9 and 10 so that each step compiles independently. **Important:** Steps 2 and 3 both add fields to separate struct literals (`new` and `new_passthrough`). Apply both before running `cargo check` in Step 5 — the code won't compile with only one updated.

- [ ] **Step 1: Add fields to `StreamingTranscriber` struct** (after `parakeet_worker`):

```rust
diarization_enabled: bool,
clear_speakers_on_start: bool,
```

- [ ] **Step 2: Initialize fields in `StreamingTranscriber::new`** (in the `Self { ... }` literal):

```rust
diarization_enabled: false,
clear_speakers_on_start: false,
```

- [ ] **Step 3: Initialize fields in `StreamingTranscriber::new_passthrough`** as well:

```rust
diarization_enabled: false,
clear_speakers_on_start: false,
```

- [ ] **Step 4: Add builder methods** after `with_stop_signal`:

```rust
pub fn with_diarization(mut self, enabled: bool) -> Self {
    self.diarization_enabled = enabled;
    self
}

pub fn with_clear_speakers_on_start(mut self, enabled: bool) -> Self {
    self.clear_speakers_on_start = enabled;
    self
}
```

- [ ] **Step 5: Confirm compilation**

```bash
cargo check --manifest-path crates/opencassava-core/Cargo.toml 2>&1
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add crates/opencassava-core/src/transcription/streaming_transcriber.rs
git commit -m "feat: add diarization_enabled and clear_speakers_on_start fields to StreamingTranscriber"
```

---

## Task 9: `OnFinal` type change — update all call sites simultaneously

This is the one mechanical-but-sweeping change. All three `OnFinal` call sites must be updated in the same commit or the code won't compile.

**Files:**
- Modify: `crates/opencassava-core/src/transcription/streaming_transcriber.rs`
- Modify: `opencassava/src-tauri/src/engine.rs`

- [ ] **Step 1: Change the `OnFinal` type alias** in `streaming_transcriber.rs` (line 9):

```rust
// Before:
pub type OnFinal = Box<dyn Fn(String) + Send + 'static>;

// After:
pub type OnFinal = Box<dyn Fn(String, Option<String>) + Send + 'static>;
```

- [ ] **Step 2: Update all `on_final(...)` call sites inside `streaming_transcriber.rs`**

In the `WhisperRs` branch (around line 128):
```rust
// Before: on_final(text);
on_final(text, None);
```

In the `FasterWhisper` branch (around line 143):
```rust
// Before: on_final(text);
on_final(text, None);
```

In the `Parakeet` branch (around line 176–179), replace:
```rust
on_final(text);
```
with a temporary placeholder (real logic comes in Task 10):
```rust
on_final(text, None);
```

The existing `Ok(_)` arm (empty text) does NOT call `on_final` — leave it unchanged (only progress). The spec pseudocode shows `on_final(text, None); continue` for empty text, but the intent is the guard: "skip `speaker_id` for empty text." All other backends (Whisper, FasterWhisper) also drop empty text without calling `on_final`, and calling it with empty text would produce empty transcript entries. Task 10 preserves this behavior.

- [ ] **Step 3: Update the two `OnFinal` closures in `engine.rs`**

**`on_them`** (around line 875). Change:
```rust
let on_them = move |text: String| {
```
to:
```rust
let on_them = move |text: String, _speaker_id: Option<String>| {
```

**`on_you`** (around line 1170). Change:
```rust
let on_you = move |text: String| {
```
to:
```rust
let on_you = move |text: String, _speaker_id: Option<String>| {
```

- [ ] **Step 4: Update test closures in `streaming_transcriber.rs`**

In the `silence_produces_no_transcription` test (around line 304):
```rust
// Before:
let on_final = move |text: String| {
    tx.send(text).ok();
};

// After:
let on_final = move |text: String, _speaker_id: Option<String>| {
    tx.send(text).ok();
};
```

In the `volatile_fires_while_speaking` test (around line 319):
```rust
// Before:
let on_final = Box::new(|_text: String| {});

// After:
let on_final = Box::new(|_text: String, _speaker_id: Option<String>| {});
```

- [ ] **Step 5: Compile and run tests**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml 2>&1
```

Expected: all existing tests pass.

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add crates/opencassava-core/src/transcription/streaming_transcriber.rs \
        opencassava/src-tauri/src/engine.rs
git commit -m "refactor: change OnFinal to Fn(String, Option<String>) — update all call sites"
```

---

## Task 10: `StreamingTranscriber` — Parakeet diarization + `clear_speakers` logic

**Files:**
- Modify: `crates/opencassava-core/src/transcription/streaming_transcriber.rs`

- [ ] **Step 1: Write a failing test** that verifies speaker_id is passed through when provided. Add to the test module:

```rust
#[tokio::test]
async fn parakeet_passthrough_speaker_id_is_none() {
    // Passthrough backend always passes None as speaker_id
    let (tx, rx) = std::sync::mpsc::channel::<Option<String>>();
    let on_final = Box::new(move |_text: String, speaker_id: Option<String>| {
        tx.send(speaker_id).ok();
    });
    // Passthrough mode is used in tests — it won't produce transcriptions
    // This test just validates the closure type compiles correctly.
    // Actual diarization path is tested via integration.
    drop(on_final);
    drop(rx);
}
```

Run:
```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml parakeet_passthrough 2>&1
```

Expected: 1 test passes (it's a compile-only test to verify closure type).

- [ ] **Step 2: Replace the Parakeet branch's `on_final` call** with the full diarization logic.

Find the current Parakeet branch in `run()` (inside `spawn_blocking`). It currently looks like:

```rust
SttBackend::Parakeet(config) => {
    let worker_result = ...;
    match worker_result {
        Ok(mut worker) => {
            if let Err(e) = worker.ensure_model() {
```

The `ensure_model` call must now pass `config.diarization_enabled`:

```rust
if let Err(e) = worker.ensure_model(config.diarization_enabled) {
```

Then after `ensure_model` succeeds, add the `clear_speakers` call (guarded by `clear_speakers_on_start`):

```rust
if clear_speakers_on_start {
    if let Err(e) = worker.clear_speakers() {
        log::warn!("[diarization] clear_speakers failed: {e}");
    }
}
```

Then replace the `on_final(text, None)` placeholder in the segment loop with the real logic:

```rust
for samples in seg_rx.iter() {
    match worker.transcribe(&samples) {
        Ok(text) if !text.is_empty() => {
            if let Some(ref on_progress) = progress_for_backend {
                on_progress(SegmentProgress::Processed);
            }
            log::info!("[transcriber] {}", &text[..text.len().min(80)]);
            let speaker_id = if diarization_enabled {
                match worker.speaker_id(&samples) {
                    Ok(id) => id,
                    Err(e) => {
                        log::warn!("[diarization] speaker_id error: {e}");
                        None
                    }
                }
            } else {
                None
            };
            on_final(text, speaker_id);
        }
        Ok(_) => {
            if let Some(ref on_progress) = progress_for_backend {
                on_progress(SegmentProgress::Processed);
            }
        }
        Err(e) => log::error!("parakeet transcribe error: {e}"),
    }
}
```

Note: `diarization_enabled` and `clear_speakers_on_start` are captured from `self` before the `spawn_blocking` closure, just like `backend`, `language`, and `prewarmed_parakeet` are. The name `progress_for_backend` is confirmed correct — it's defined at line 95 of the current `streaming_transcriber.rs` as `let progress_for_backend = on_progress.clone();`. Add at the top of `run()` alongside those captures:

```rust
let diarization_enabled = self.diarization_enabled;
let clear_speakers_on_start = self.clear_speakers_on_start;
```

- [ ] **Step 3: Compile and run all tests**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml 2>&1
```

Expected: all tests pass.

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add crates/opencassava-core/src/transcription/streaming_transcriber.rs
git commit -m "feat: wire diarization into Parakeet branch of StreamingTranscriber"
```

---

## Task 11: `engine.rs` — `speaker_id_to_label` helper

**Files:**
- Modify: `opencassava/src-tauri/src/engine.rs`

- [ ] **Step 1: Write failing tests** — add a `#[cfg(test)]` module at the bottom of `engine.rs` (the file doesn't currently have one at that level — add it):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speaker_id_to_label_parses_speaker_0() {
        let (pid, label) = speaker_id_to_label("speaker_0");
        assert_eq!(pid, "speaker_0");
        assert_eq!(label, "Speaker 1");
    }

    #[test]
    fn speaker_id_to_label_parses_speaker_4() {
        let (pid, label) = speaker_id_to_label("speaker_4");
        assert_eq!(pid, "speaker_4");
        assert_eq!(label, "Speaker 5");
    }

    #[test]
    fn speaker_id_to_label_falls_back_on_bad_format() {
        let (pid, label) = speaker_id_to_label("unknown");
        assert_eq!(pid, "remote_1");
        assert_eq!(label, "Speaker A");
    }

    #[test]
    fn speaker_id_to_label_falls_back_on_non_integer() {
        let (pid, label) = speaker_id_to_label("speaker_abc");
        assert_eq!(pid, "remote_1");
        assert_eq!(label, "Speaker A");
    }
}
```

- [ ] **Step 2: Run tests — confirm they fail** (function doesn't exist yet):

```bash
cargo test --manifest-path opencassava/src-tauri/Cargo.toml speaker_id_to_label 2>&1
```

Expected: compile error.

- [ ] **Step 3: Add the helper function** to `engine.rs` near the other helper functions (e.g., after `resolve_transcription_language`):

```rust
/// Maps a Python worker speaker ID (e.g. "speaker_0") to a (participant_id, participant_label) pair.
/// Falls back to ("remote_1", "Speaker A") for unrecognised formats.
fn speaker_id_to_label(id: &str) -> (String, String) {
    if let Some(n_str) = id.strip_prefix("speaker_") {
        if let Ok(n) = n_str.parse::<usize>() {
            return (id.to_string(), format!("Speaker {}", n + 1));
        }
    }
    ("remote_1".to_string(), "Speaker A".to_string())
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```bash
cargo test --manifest-path opencassava/src-tauri/Cargo.toml speaker_id_to_label 2>&1
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add opencassava/src-tauri/src/engine.rs
git commit -m "feat: add speaker_id_to_label helper with tests"
```

---

## Task 12: `engine.rs` — update `on_them`, `on_you`, and transcriber construction

**Files:**
- Modify: `opencassava/src-tauri/src/engine.rs`

- [ ] **Step 1: Update `on_them` closure** to use `speaker_id` for participant fields.

The closure currently starts at around line 875. The signature was already updated to `|text: String, _speaker_id: Option<String>|` in Task 9. Now replace `_speaker_id` with the real name and use it:

Change:
```rust
let on_them = move |text: String, _speaker_id: Option<String>| {
```
to:
```rust
let on_them = move |text: String, speaker_id: Option<String>| {
```

Add the helper call at the top of the closure body (before `let utterance = ...`):

```rust
let (participant_id, participant_label) = match &speaker_id {
    Some(id) => speaker_id_to_label(id),
    None => ("remote_1".to_string(), "Speaker A".to_string()),
};
```

Replace every hardcoded `"remote_1"` and `"Speaker A"` inside this closure with `participant_id.clone()` and `participant_label.clone()` respectively. There are four occurrences total — in `Utterance`, `TranscriptPayload`, `SessionRecord`, and `transcript_logger.append(...)`.

The closure should end up like:

```rust
let on_them = move |text: String, speaker_id: Option<String>| {
    if !*state_sg.is_running.lock().unwrap() {
        return;
    }
    let (participant_id, participant_label) = match &speaker_id {
        Some(id) => speaker_id_to_label(id),
        None => ("remote_1".to_string(), "Speaker A".to_string()),
    };
    use opencassava_core::models::{Speaker, Utterance};
    let utterance = Utterance {
        id: uuid::Uuid::new_v4(),
        text: text.clone(),
        speaker: Speaker::Them,
        participant_id: Some(participant_id.clone()),
        participant_label: Some(participant_label.clone()),
        timestamp: chrono::Utc::now(),
    };
    let payload = TranscriptPayload {
        text: text.clone(),
        speaker: "them".into(),
        participant_id: participant_id.clone(),
        participant_label: participant_label.clone(),
    };
    app_sg.emit("transcript", &payload).ok();
    let record = SessionRecord {
        speaker: Speaker::Them,
        participant_id: Some(participant_id.clone()),
        participant_label: Some(participant_label.clone()),
        text: text.clone(),
        timestamp: chrono::Utc::now(),
        suggestions: None,
        kb_hits: None,
        suggestion_decision: None,
        surfaced_suggestion_text: None,
        conversation_state_summary: None,
    };
    state_sg.session_store.lock().unwrap().append_record(&record).ok();
    state_sg.transcript_logger.lock().unwrap().append(
        &participant_label,
        &text,
        chrono::Utc::now(),
    );
    push_recent_utterance(
        &recent_utterances_clone,
        utterance.clone(),
        suggestion_context_window_secs,
    );
};
```

- [ ] **Step 2: Wire builder methods onto the Them-stream transcriber**

Find the Them-stream transcriber construction (around line 964):

```rust
let mut transcriber =
    StreamingTranscriber::new(them_backend, them_lang, Box::new(on_them))
    .with_volatile(Box::new(on_them_vol))
    .with_progress(on_them_progress)
    .with_stop_signal(Arc::clone(&them_state.stop_requested));
```

Add the two new builder calls:

```rust
let mut transcriber =
    StreamingTranscriber::new(them_backend, them_lang, Box::new(on_them))
    .with_volatile(Box::new(on_them_vol))
    .with_progress(on_them_progress)
    .with_stop_signal(Arc::clone(&them_state.stop_requested))
    .with_diarization(settings.diarization_enabled)
    .with_clear_speakers_on_start(true);
```

- [ ] **Step 3: Wire builder methods onto the You-stream transcriber**

Find the You-stream transcriber construction (a few hundred lines later, around line 1220). It will look like:

```rust
let mut you_transcriber =
    StreamingTranscriber::new(backend.clone(), language.clone(), Box::new(on_you))
    ...
```

Add (note: diarization is always disabled for mic):

```rust
    .with_diarization(false)
    .with_clear_speakers_on_start(false)
```

- [ ] **Step 4: Compile and run all tests**

```bash
cargo test --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add opencassava/src-tauri/src/engine.rs
git commit -m "feat: use speaker_id in on_them closure and wire diarization into transcribers"
```

---

## Task 13: Frontend — speaker diarization toggle

**Files:**
- Modify: `opencassava/src/components/SettingsView.tsx`

- [ ] **Step 1: Add the toggle** in the Parakeet settings section, after the Device `<select>` block and before the closing `</>` of the Parakeet branch (around line 969, just before `</>`) :

```tsx
<div style={styles.fieldWrap}>
  <label style={styles.labelStyle}>Speaker diarization</label>
  <div style={{ display: "flex", alignItems: "center", gap: spacing[2] }}>
    <input
      type="checkbox"
      id="diarization-toggle"
      checked={settings.diarizationEnabled ?? true}
      onChange={(e) =>
        saveSettings({ ...settings, diarizationEnabled: e.target.checked })
      }
    />
    <label htmlFor="diarization-toggle" style={{ fontSize: typography.sm, color: colors.text, cursor: "pointer" }}>
      Enabled
    </label>
  </div>
  <span style={{ fontSize: typography.sm, color: colors.textMuted, marginTop: 4, display: "block" }}>
    Automatically identify different speakers in call audio
  </span>
</div>
```

- [ ] **Step 2: Build the frontend**

```bash
cd opencassava && npm run build 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add opencassava/src/components/SettingsView.tsx
git commit -m "feat: add speaker diarization toggle to Parakeet settings"
```

---

## Final Verification

- [ ] **Full compile check**

```bash
cargo check --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: no errors or warnings related to this feature.

- [ ] **Full test suite**

```bash
cargo test --manifest-path crates/opencassava-core/Cargo.toml 2>&1
cargo test --manifest-path opencassava/src-tauri/Cargo.toml 2>&1
```

Expected: all tests pass.

- [ ] **TypeScript build**

```bash
cd opencassava && npm run build 2>&1 | tail -10
```

Expected: no new errors.

- [ ] **Tag the feature complete**

```bash
git log --oneline -13
```

Should show the 13 commits from this plan, ending with the settings commit at the bottom.
