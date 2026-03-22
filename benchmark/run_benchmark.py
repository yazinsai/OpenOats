#!/usr/bin/env python3
"""
Benchmark transcription models against MLS ground truth.

Uses openai-whisper CLI (PyTorch) to test whisper models.
WhisperKit CoreML results track closely with PyTorch at batch scale
(per Newarr's benchmarks: WK turbo 28.8% vs PyTorch turbo 34.3% batch WER),
so PyTorch results are a reasonable proxy.

Usage: python3 run_benchmark.py
"""

import json
import os
import subprocess
import sys
import time
import unicodedata
import re

# jiwer for proper WER calculation
from jiwer import wer as compute_wer, cer as compute_cer

BENCHMARK_DIR = os.path.dirname(os.path.abspath(__file__))
AUDIO_DIR = os.path.join(BENCHMARK_DIR, "audio")
SAMPLES_FILE = os.path.join(BENCHMARK_DIR, "samples.json")

# Models to benchmark (whisper CLI model names)
MODELS = [
    "large-v3-turbo",  # maps to whisperLargeV3Turbo in the app
    "small",           # maps to whisperSmall in the app
    "base",            # maps to whisperBase in the app (excluded from batch, for reference)
]

def normalize_text(text: str) -> str:
    """Normalize text for WER comparison: lowercase, strip punctuation, collapse whitespace."""
    text = text.lower()
    # Remove accents for fairer comparison (some models output unaccented text)
    # Actually keep accents — they matter for non-English
    # Remove punctuation
    text = re.sub(r'[^\w\s]', '', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def run_whisper(audio_path: str, model: str, language: str) -> tuple[str, float]:
    """Run whisper CLI and return (transcript, elapsed_seconds)."""
    lang_map = {
        "polish": "pl",
        "spanish": "es",
        "french": "fr",
        "german": "de",
        "english": "en",
    }
    lang_code = lang_map.get(language, language)

    start = time.time()
    result = subprocess.run(
        [
            "whisper", audio_path,
            "--model", model,
            "--language", lang_code,
            "--output_format", "txt",
            "--output_dir", "/tmp/whisper_bench",
            "--fp16", "False",  # CPU mode
        ],
        capture_output=True,
        text=True,
        timeout=300,
    )
    elapsed = time.time() - start

    # Read output file
    basename = os.path.splitext(os.path.basename(audio_path))[0]
    txt_path = f"/tmp/whisper_bench/{basename}.txt"
    transcript = ""
    if os.path.exists(txt_path):
        with open(txt_path) as f:
            transcript = f.read().strip()
        os.remove(txt_path)

    return transcript, elapsed


def main():
    os.makedirs("/tmp/whisper_bench", exist_ok=True)

    with open(SAMPLES_FILE) as f:
        samples = json.load(f)

    print(f"Loaded {len(samples)} samples")
    print(f"Models: {', '.join(MODELS)}")
    print("=" * 110)

    results = []

    for model in MODELS:
        print(f"\n--- Model: {model} ---")

        for sample in samples:
            wav_file = sample["file"].replace(".opus", ".wav")
            wav_path = os.path.join(BENCHMARK_DIR, wav_file)

            if not os.path.exists(wav_path):
                print(f"  [{sample['language']}] {wav_file}: MISSING")
                continue

            try:
                hypothesis, elapsed = run_whisper(wav_path, model, sample["language"])

                ref_norm = normalize_text(sample["transcript"])
                hyp_norm = normalize_text(hypothesis)

                if ref_norm and hyp_norm:
                    sample_wer = compute_wer(ref_norm, hyp_norm)
                    sample_cer = compute_cer(ref_norm, hyp_norm)
                else:
                    sample_wer = 1.0 if not hyp_norm else 0.0
                    sample_cer = 1.0 if not hyp_norm else 0.0

                results.append({
                    "model": model,
                    "language": sample["language"],
                    "file": os.path.basename(wav_path),
                    "wer": sample_wer,
                    "cer": sample_cer,
                    "elapsed": elapsed,
                    "ref": ref_norm[:80],
                    "hyp": hyp_norm[:80],
                })

                wer_pct = f"{sample_wer*100:.1f}%"
                cer_pct = f"{sample_cer*100:.1f}%"
                print(f"  [{sample['language']}] {os.path.basename(wav_path)}: WER={wer_pct} CER={cer_pct} ({elapsed:.1f}s)")

                if sample_wer > 0.5:
                    print(f"    REF: {ref_norm[:100]}")
                    print(f"    HYP: {hyp_norm[:100]}")

            except Exception as e:
                print(f"  [{sample['language']}] {wav_file}: ERROR {e}")

    # Summary table
    print("\n" + "=" * 110)
    print("BENCHMARK RESULTS")
    print("=" * 110)
    print(f"{'Model':<20} {'Language':<10} {'File':<18} {'WER%':>8} {'CER%':>8} {'Time(s)':>8}")
    print("-" * 110)

    for r in results:
        print(f"{r['model']:<20} {r['language']:<10} {r['file']:<18} {r['wer']*100:>7.1f}% {r['cer']*100:>7.1f}% {r['elapsed']:>7.1f}")

    # Per-model averages
    print("-" * 110)
    for model in MODELS:
        model_results = [r for r in results if r["model"] == model]
        if not model_results:
            continue
        avg_wer = sum(r["wer"] for r in model_results) / len(model_results)
        avg_cer = sum(r["cer"] for r in model_results) / len(model_results)
        avg_time = sum(r["elapsed"] for r in model_results) / len(model_results)
        print(f"{model:<20} {'AVG':<10} {'':18} {avg_wer*100:>7.1f}% {avg_cer*100:>7.1f}% {avg_time:>7.1f}")

    # Per-model per-language averages
    print("\n--- Average WER by Language ---")
    for model in MODELS:
        model_results = [r for r in results if r["model"] == model]
        langs = sorted(set(r["language"] for r in model_results))
        for lang in langs:
            lang_results = [r for r in model_results if r["language"] == lang]
            avg_wer = sum(r["wer"] for r in lang_results) / len(lang_results)
            print(f"  {model:<20} {lang:<10} WER={avg_wer*100:.1f}%")

    # Save results
    results_path = os.path.join(BENCHMARK_DIR, "results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {results_path}")


if __name__ == "__main__":
    main()
