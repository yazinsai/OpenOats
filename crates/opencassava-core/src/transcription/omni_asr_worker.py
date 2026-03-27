import json
import os
import sys
import numpy as np

MODELS = {}

def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()

def handle_health():
    emit({"ok": True, "result": {"status": "ready"}})

def _clean_fairseq2_stale_tmp():
    """
    Remove stale tmp* files from the fairseq2 asset cache.

    When a checkpoint cache directory contains both a complete .pt file and
    leftover tmp* files from an interrupted download, fairseq2's cache resolver
    returns the directory path instead of the .pt file path.  The delegating
    checkpoint loader then fails because none of its loaders (basic/native/
    safetensors) accept a plain directory.  Removing the orphan tmp files lets
    the resolver return the .pt file path directly, which basic.py handles.
    """
    import pathlib
    cache = pathlib.Path.home() / ".cache" / "fairseq2" / "assets"
    removed = []
    if cache.exists():
        for f in cache.glob("*/tmp*"):
            if f.is_file():
                try:
                    f.unlink()
                    removed.append(f.name)
                except OSError:
                    pass
    if removed:
        sys.stderr.write(f"[omni-asr] Removed stale fairseq2 cache tmp file(s): {', '.join(removed)}\n")
        sys.stderr.flush()


def _load_pipeline(model_name, device):
    from omnilingual_asr.models.inference import ASRInferencePipeline
    # device=None lets the pipeline auto-select (cuda if available, else cpu)
    dev = None if device in ("auto", None, "") else device
    # Purge any orphan tmp* files left by a previously interrupted download.
    # Their presence causes the fairseq2 cache resolver to return a directory
    # path instead of the resolved .pt path, breaking the delegating loader.
    _clean_fairseq2_stale_tmp()
    return ASRInferencePipeline(model_name, device=dev)

def handle_ensure_model(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    if model_name not in MODELS:
        MODELS[model_name] = _load_pipeline(model_name, device)
    emit({"ok": True, "result": {"model": model_name}})

def handle_transcribe(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    samples = np.asarray(payload.get("samples", []), dtype=np.float32)

    if model_name not in MODELS:
        MODELS[model_name] = _load_pipeline(model_name, device)

    pipeline = MODELS[model_name]

    # Pass as a pre-decoded audio dict — no temp file needed.
    # The pipeline resamples, normalises, and processes from here.
    audio_input = {"waveform": samples, "sample_rate": 16000}
    lang = payload.get("lang")  # fairseq2 code e.g. "eng_Latn", or None for auto
    lang_list = [lang] if lang else None
    results = pipeline.transcribe([audio_input], lang=lang_list)
    text = results[0].strip() if results else ""

    # For CTC models, lang is ignored and the model auto-detects. When the
    # caller requested a Latin-script language (e.g. eng_Latn) but the output
    # contains only non-Latin characters, the model misidentified the language
    # — drop the result rather than surfacing garbage.
    if lang and lang.endswith("_Latn") and text:
        latin_chars = sum(1 for ch in text if ch.isascii() or "A" <= ch <= "\u024f")
        if latin_chars == 0:
            text = ""

    emit({"ok": True, "result": {"text": text}})

def main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            payload = json.loads(line)
            command = payload.get("command")
            if command == "health":
                handle_health()
            elif command == "ensure_model":
                handle_ensure_model(payload)
            elif command == "transcribe":
                handle_transcribe(payload)
            elif command == "shutdown":
                emit({"ok": True, "result": {"shutdown": True}})
                return
            else:
                emit({"ok": False, "error": f"Unknown command: {command}"})
        except Exception as exc:
            import traceback
            emit({"ok": False, "error": str(exc), "traceback": traceback.format_exc()})

if __name__ == "__main__":
    main()
