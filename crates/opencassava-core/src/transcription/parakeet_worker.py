import json
import os
import sys
import tempfile

import numpy as np
import soundfile as sf


MODELS = {}


def model_key(model_name: str, device: str) -> str:
    return f"{model_name}::{device}"


def load_model(model_name: str, device: str):
    key = model_key(model_name, device)
    if key in MODELS:
        return MODELS[key]

    import nemo.collections.asr as nemo_asr

    model = nemo_asr.models.ASRModel.from_pretrained(model_name=model_name)
    model.eval()

    if device and device not in ("auto", "cpu"):
        try:
            import torch
            model = model.to(torch.device(device))
        except Exception:
            pass

    MODELS[key] = model
    return model


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def handle_health():
    emit({"ok": True, "result": {"status": "ready"}})


def handle_ensure_model(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    load_model(model_name, device)
    emit({"ok": True, "result": {"model": model_name}})


def handle_transcribe(payload):
    model_name = payload["model"]
    device = payload.get("device", "auto")
    samples = np.asarray(payload.get("samples", []), dtype=np.float32)

    model = load_model(model_name, device)

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
        sf.write(tmp_path, samples, 16000)

        transcriptions = model.transcribe([tmp_path])
        raw = transcriptions[0] if transcriptions else ""
        text = raw.text if hasattr(raw, "text") else str(raw)
        emit({"ok": True, "result": {"text": text.strip()}})
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


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
            emit({"ok": False, "error": str(exc)})


if __name__ == "__main__":
    main()
