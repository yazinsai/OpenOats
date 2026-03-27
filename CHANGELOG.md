# Changelog

All notable changes to OpenCassava are documented here.

Format: `## [version] — title` followed by grouped bullet points.
The release workflow reads this file and extracts the section that matches the
current tag, so keep each release block between its own `## [x.y.z]` header
and the next one.

---

## [0.2.0] — Omni-ASR WSL2 overhaul

Full end-to-end repair of the Omni-ASR pipeline on Windows via WSL2, fixing a
series of cascading installation and runtime issues discovered during testing.

### Installation fixes

- **Venv moved to Linux-native filesystem** — virtual environment now lives under
  `$HOME/.local/share/opencassava/omni-asr/venv` inside WSL2 (ext4), not on the
  Windows NTFS mount (`/mnt/c/…`). PyTorch `.so` files cannot be loaded by the
  Linux dynamic linker from NTFS; this was the root cause of the
  `libcudart.so.13: cannot open shared object file` error.
- **CPU torch pre-installed before omnilingual-asr** — `torch==2.6.0` and
  `torchaudio==2.6.0` are now installed from the PyTorch CPU index *before*
  `omnilingual-asr` resolves its dependencies, preventing pip from pulling CUDA
  builds from PyPI.
- **`libsndfile.so.1` symlink created automatically** — `fairseq2n` looks for
  `libsndfile.so.1` at runtime; the installer now symlinks it from `soundfile`'s
  bundled `libsndfile_x86_64.so`, so `apt install libsndfile1` is not required.
- **`LD_LIBRARY_PATH` set on worker spawn** — the worker process launches with
  `LD_LIBRARY_PATH='{venv}/lib'` so the dynamic linker finds the symlink.
- **Reinstall loop eliminated** — `install_runtime` returns early when the install
  stamp is valid, preventing pip from reinstalling everything on every launch.
- **Stale lock auto-cleared** — a `setup.lock` left by a crashed install is
  removed automatically on the next health check if the runtime is installed.
- **Cleanup on failure** — a partial venv is deleted when installation fails so
  the next attempt always starts from scratch.

### Runtime fixes

- **Correct import path** — worker was importing from `omnilingual_asr.pipelines`
  (does not exist); fixed to `omnilingual_asr.models.inference`.
- **Correct API usage** — worker was calling `ASRInferencePipeline.from_pretrained`
  (does not exist); fixed to `ASRInferencePipeline(model_card, device=device)`
  constructor and `pipeline.transcribe([audio_dict])` returning `List[str]`.
- **No temp WAV file** — audio is now passed as a pre-decoded dict directly to the
  pipeline, eliminating the write/read cycle.
- **Model pre-loaded on record** — `ensure_model()` is called immediately after the
  worker spawns so the 1+ GB checkpoint loads up front with log output, rather
  than silently blocking the first audio chunk.
- **Full tracebacks in error responses** — Python exceptions now include the
  traceback in the JSON error payload for easier debugging.

### Model names & settings

- **Correct fairseq2 card names** — the app was using HuggingFace-style paths
  (`facebook/omnilingual-asr-300m`) which are not valid fairseq2 card names.
  Correct names are `omniASR_CTC_300M`, `omniASR_CTC_1B`, `omniASR_LLM_300M`, etc.
- **Automatic migration** — saved settings with old HuggingFace-style names are
  remapped to correct fairseq2 names on load; no manual action needed.
- **Updated model dropdown** — Settings now lists all six models
  (CTC 300M / 1B / 3B and LLM 300M / 1B / 7B) with descriptions.
- **Default model** is `omniASR_CTC_300M` — fast and reliable. LLM models
  (`omniASR_LLM_*`) are available in the dropdown but require a complete
  multi-shard download; select them manually once the download finishes.

### Language conditioning

- **`lang` wired through** — transcription locale (e.g. `en`) is mapped to a
  fairseq2 language code (e.g. `eng_Latn`) and passed to `pipeline.transcribe`.
- **LLM models honor language** — `omniASR_LLM_*` models output in the requested
  language regardless of the audio's detected language.
- **CTC garbage filter** — when a Latin-script language is requested but the CTC
  model returns entirely non-Latin characters (Arabic etc. from misdetection on
  short/noisy clips), the result is silently dropped instead of surfaced as
  garbage text.

- **Recommendation updated** - Omni-ASR remains available, but it is not the
  recommended engine for this release. Parakeet is the preferred STT backend
  and our current recommendation for day-to-day use.

### Bug fixes

- **UTF-8 panic in log pump** — `pump_stderr` panicked when a Unicode progress-bar
  character (`▊`, `█`) fell on a non-char-boundary byte offset. Fixed by snapping
  the truncation index to the next valid char boundary.
- **Log line whitespace** — tqdm progress bars pad lines with trailing spaces for
  `\r` overwriting; these are now trimmed before logging.

---

## [0.1.6] — Previous release

See git history for changes prior to v0.2.0.
