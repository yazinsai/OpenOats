# OpenOats 2.0 plan

OpenOats 2.0 records a meeting and, after Stop, turns it into one markdown file: Notes on top, a You/Them Transcript underneath. Nothing runs during the call except the recorder. Terms are defined in [GLOSSARY.md](GLOSSARY.md); the reasons behind the big decisions are in [docs/adr](docs/adr).

## Goals

- **Simple to use.** Install, grant permissions, press Start. No account, key or settings needed.
- **Light on the Mac.** Near-idle while recording; models load only during Processing and unload after.
- **Accurate after the call.** Whole-track transcription, plus optional Vocabulary correction.
- **Flexible for those who want it.** Any Transcription backend or Notes backend, behind one settings tab.
- **Never loses a Meeting.** Crash, force quit or dead battery costs at most a few seconds of audio.

## Budgets

| | Target |
|---|---|
| Idle memory | < 60 MB |
| CPU while recording | < 3% of one core |
| On-device Processing | ≤ 3 min per hour of audio on M1 (benchmark: ~2 min/hour Parakeet v3) |
| Audio lost on abrupt end | ≤ 5 s |
| App source size | < 6k lines (1.x: ~46k) |

## User experience

**Menu bar** (the app has no Dock icon unless the window is open):
Start / Stop, elapsed time and two level meters while recording, the Processing queue, Open OpenOats, Settings, Quit. A global hotkey toggles recording.

**Meeting detection** (2.1, on by default): when a Call app records from the mic for 5 s while it plays audio or a camera is on (the camera never prompts alone), one "Record this meeting?" notification (click or Record; "Don't Ask for <app>"), and the menu's button reads "Record <app> Call". A recording started that way stops when the app leaves the mic for 20 s. Settings → General turns it off and lists ignored apps.

**After Stop:** a notification when the Meeting file is ready; clicking opens it.

**Window** (freely resizable): a meeting list on the left (title, date, duration, state: Recording, Processing, Needs attention, Interrupted), the rendered Meeting file on the right. Actions: Rename, Copy, Open in editor, Show in Finder, Show audio in Finder, Re-process, Delete. Drop an audio file anywhere to import it.

**Onboarding** (one screen): mic permission, system audio permission, a one-line recording-consent acknowledgement, notes folder. The on-device model downloads in the background.

**Settings**, three tabs:
- *General:* notes folder, language (defaults to the system language), hotkey, Vocabulary.
- *AI:* Notes backend (None by default, or a Preset plus key and model), Transcription backend (On-device by default, or a cloud/self-hosted option). Each has a Test button.
- *Advanced:* notes prompt with Reset, delete audio after Processing (off).

## Pipeline

```
Start ─► Recorder ─► mic.pcm + system.pcm  (flushed every ~2 s, status: recording)
Stop  ─► queue ─► Processing (background priority, one Meeting at a time)
           1. transcribe each track          ─► mic.json, system.json     checkpoint
           2. merge by time into You/Them,
              drop Mic-track echoes of Them   ─► transcript.json           checkpoint
           3. Vocabulary correction + Notes   ─► notes.json                checkpoint (skipped if no Notes backend)
           4. write Meeting file to notes folder, compress tracks to .m4a
        ─► status: done   (any failure ─► Needs attention, Retry resumes from last checkpoint)
```

- **Working folder:** `~/Library/Application Support/OpenOats/Meetings/<id>/` holds the tracks, `meeting.json` (state, completed steps, backend used, errors) and the checkpoints.
- **Recovery:** on launch, Meetings left in `recording` are closed at the last flushed sample and queued, Meetings left in `processing` resume; the Meeting file gets `interrupted: true`, and a notification says what was recovered.
- **Recording robustness:** keep the Mac awake while recording; follow default-device changes without stopping; write silence over gaps so tracks stay aligned; refuse to start below 1 GB free, warn at 500 MB, stop cleanly at 200 MB.
- **Echo removal:** a Mic-track segment that overlaps a System-track segment in time with high text similarity is dropped. Tuned on real speaker-not-headphones recordings in M1.
- **Re-process:** replace the Meeting file only if its content hash matches what the app last wrote; otherwise write `<name> (2).md`.
- **Meeting file:** follows [docs/meeting-format-spec.md](docs/meeting-format-spec.md); bump to v2 only if track/speaker fields need to change. Title comes from the Notes backend, else date and time; renaming renames the file.

## Backends

| Slot | Types (code) | Presets (data only) |
|---|---|---|
| Transcription | On-device · OpenAI-style `/audio/transcriptions` · ElevenLabs · AssemblyAI · Gemini | OpenAI, Groq, self-hosted Whisper server |
| Notes | None · OpenAI-compatible chat · Anthropic · Gemini | OpenAI, OpenRouter, Requesty, Ollama, LM Studio, MLX, llama.cpp |

- **On-device:** Parakeet v3 (FluidAudio) for its 25 European languages, Whisper large-v3-turbo (WhisperKit) for everything else, picked by the language setting. Never shown as a model list.
- **Cloud transcription** uploads the compressed track per track, so You/Them stays exact; long tracks are chunked to fit each API's limits.
- **Notes backend** sees only text. Vocabulary correction is limited to names and terms; the Transcript is otherwise left verbatim. Long transcripts that exceed the model's context are summarised in pieces.
- API keys live in the Keychain.

## Code layout

```
OpenOats/
  Sources/
    OatsCore/        recorder, Processing pipeline, backends, Meeting store, settings, 1.x migration
    oats/            CLI: oats transcribe <audio> [<system-audio>], oats notes <meeting>, oats process <id>
    OpenOats/        SwiftUI app: menu bar, window, settings, onboarding
  Tests/OatsCoreTests/
```

**Reused from 1.x** (copied and trimmed, not linked): `MicCapture`, `SystemAudioCapture` (incl. the Sonoma fix), `AcousticEchoFilter` (evaluate), `ParakeetBackend`, `WhisperKitManager`, `MarkdownMeetingWriter`, `TextSimilarity`, the Sparkle updater. Everything else stays in 1.x.

## Migration from 1.x

On first v2 launch, once, silently: read the `com.openoats.app` defaults and Keychain items, then carry over notes folder, Vocabulary, language and API keys, and map the LLM provider and transcription model to the nearest backend/Preset (fallback: defaults). Existing Meeting files in the notes folder appear in the list; 1.x session JSONL files are left untouched.

## Milestones

Each milestone ends with something runnable and its checks passing.

0. **Freeze 1.x.** Branch `1.x` from `main`; 1.x gets fixes only from now on.
1. **Core + CLI.** `oats transcribe mic.wav system.wav > meeting.md` with Parakeet and Whisper, merge, echo removal, Meeting file writer.
   *Check:* golden test on the Nov 12 10-minute clip beats the 1.x live transcript (no mid-sentence splits, no dropped speech); echo removal on a speaker-not-headphones recording.
2. **Notes backends.** OpenAI-compatible, Anthropic, Gemini, Presets, Vocabulary correction, notes prompt, chunked summarising.
   *Check:* the same clip through cliproxy and a local Ollama model; "an arai" → "Almarai" with Vocabulary set.
3. **Crash-safe recorder.** PCM writers, `meeting.json`, checkpoints, recovery, device changes, disk thresholds.
   *Check:* automated `kill -9` mid-recording and mid-Processing, then relaunch recovers with ≤ 5 s lost; AirPods disconnect keeps recording.
4. **App shell.** Menu bar, window, settings, onboarding, notifications, hotkey, import by drag and drop.
   *Check:* UI smoke suite rewritten for v2; budgets measured on a 1-hour recording.
5. **Cloud transcription.** OpenAI-style, ElevenLabs, AssemblyAI, Gemini, with chunking and retry.
   *Check:* each backend on the Nov 12 clip.
6. **Migration and release.** 1.x settings import, Sparkle feed, Homebrew cask, CI workflows updated for the new layout, release notes listing what was removed.
   *Check:* upgrade a real 1.x install in place. `release:major` needs owner approval.

## Out of scope for 2.0

Live transcript or captions, suggestions, knowledge base, embeddings, Sidecast, Ask, calendar, webhooks, Apple Notes, Granola import, templates, mini bar and overlays, splitting Them into named people. Meeting detection returns in 2.1 as a "Record this meeting?" prompt ([ADR 0005](docs/adr/0005-meeting-detection-asks-about-the-app-on-the-mic.md)).

## Risks

- **Echo removal on speakers** is the hardest correctness problem; if similarity matching isn't enough, fall back to the 1.x acoustic echo filter at Processing time.
- **Whisper large-v3-turbo memory** (~1.5 GB while loaded) only matters for non-European languages and only during Processing.
- **Users who relied on removed features** will notice; the release notes say so plainly and 1.x stays downloadable.
