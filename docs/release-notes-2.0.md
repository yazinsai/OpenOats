<!-- Draft for the v2.0.0 GitHub release body. The release workflow embeds the release body in the
Sparkle update dialog, so 1.x users read this before they choose to update. The "Rolling out 2.0"
section at the end is for the maintainer; delete it from the release body. -->

# OpenOats 2.0

OpenOats 2.0 is a different app. It records your meeting and, after you press Stop, turns it into one markdown file: notes at the top, a You/Them transcript underneath. Nothing is transcribed during the call, so the app stays close to idle while it records.

**If you rely on live transcripts, suggestions or the knowledge base, stay on 1.x.** Click "Skip This Version" in the update dialog. 1.x stays downloadable (see below) and gets fixes for a while.

## What's new

- **Better transcripts.** Each side of the call is transcribed as a whole after Stop, instead of in live chunks. Sentences no longer break mid-way and less speech gets dropped.
- **You and Them come from the audio itself.** Your mic is You, system audio is Them. Echo of the other side picked up by your mic is removed.
- **Crash-safe recording.** Audio is written to disk every couple of seconds. After a crash, force quit or dead battery, the meeting is recovered on next launch, minus a few seconds at most.
- **Light on your Mac.** Models load only while a meeting is processed, then unload.
- **On-device by default.** Parakeet v3 for 25 European languages, Whisper large-v3-turbo for everything else, picked from your language setting. No account or key needed.
- **Any backend if you want one.** Cloud or self-hosted transcription (OpenAI-style, Groq, ElevenLabs, AssemblyAI, Gemini, a local Whisper server) and an optional notes model (OpenAI-compatible including OpenRouter, Requesty, Ollama, LM Studio; Anthropic; Gemini). The notes model only sees text.
- **Vocabulary.** Add names and terms, and the notes step fixes them in the transcript.
- **Import.** Drop an audio file on the window to process it like a meeting.
- **Command line.** `OpenOats.app/Contents/MacOS/oats` transcribes and processes meetings from the terminal.

## What was removed

These are gone from 2.0, not hidden behind a setting:

- Live transcript and live captions
- Live suggestions and talking points
- Knowledge base and embeddings (Voyage AI, Ollama and OpenAI-compatible embeddings)
- Sidecast
- Ask
- Calendar integration and meeting detection (a "Record this meeting?" prompt is planned for 2.1)
- Webhooks
- Apple Notes export
- Granola import
- Meeting templates (there is one notes prompt, editable under Settings > Advanced)
- Mini bar and overlays, including hiding the window from screen sharing
- Transcription models: Bark+, Qwen3 ASR, Parakeet v2, the smaller Whisper models (base, small) and Cohere Arabic. Meetings that used them are transcribed on-device with Parakeet v3 or Whisper large-v3-turbo instead.

## What carries over

On first launch, once, 2.0 reads your 1.x settings and keeps:

- your notes folder, language and Vocabulary (custom words)
- your API keys, still in the Keychain
- your LLM provider, mapped to the nearest notes backend; it falls back to no notes when its key is missing
- your transcription choice, mapped to on-device or the same cloud service
- the "save audio" choice, as "delete audio after processing"

Meeting files already in your notes folder show up in the meeting list. 1.x session logs are left untouched, and nothing is uploaded or deleted.

1.x model downloads are not removed automatically. To free the space, delete what you no longer need under `~/Library/Application Support/OpenOats/Models/Transcription` (for example `qwen3-asr`, about 4 GB) and `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`.

## Staying on 1.x

The last 1.x release stays on the [releases page](https://github.com/yazinsai/OpenOats/releases), and the code lives on the [`1.x` branch](https://github.com/yazinsai/OpenOats/tree/1.x). To go back after updating, quit OpenOats, download the latest 1.x DMG and drag it over `/Applications/OpenOats.app`. Your 1.x settings and sessions are still there, since 2.0 only reads them.

## Requirements

Apple Silicon Mac, macOS 14.2 (Sonoma) or later. Microphone and system audio recording permissions.

---

## Rolling out 2.0 (maintainer only, remove from the release body)

The Sparkle feed (`gh-pages/appcast.xml`) holds one item, and both 1.x and 2.0 read it. Publishing 2.0 as a normal release would offer it to every 1.x user at their next update check. The release workflow now guards against that:

1. **Held by default.** When the feed holds a different major version (1.90.x now), `scripts/write_appcast.py` leaves it unchanged and logs a warning. The DMG is still attached to the release, and the Homebrew cask still moves to 2.0.0. Prereleases never touch the feed or the cask, so a `v2.0.0-beta.N` prerelease is a safe way to hand out test builds.
2. **Opt in.** Set the repository variable `SPARKLE_MAJOR_UPGRADE_APPROVED=2`, then rerun "Build macOS DMG" with `workflow_dispatch` and tag `v2.0.0`.
3. **Optional phased rollout.** Also set `SPARKLE_PHASED_ROLLOUT_INTERVAL` (seconds, e.g. `86400`). Sparkle then offers the update to one of 7 groups per interval, so 1 day means all users within a week. Manual "Check for Updates" always sees it straight away. Clear the variable afterwards if 2.0.x fixes should go out to everyone at once.
4. **Never silent.** Every item now carries `sparkle:minimumAutoupdateVersion` = `<major>.0.0`, so a 1.x install is always asked before jumping to 2.x, even with automatic install turned on. Within 2.x, updates install as usual. If a 1.x user clicks "Skip This Version", Sparkle also skips later 2.x items with the same minimum, so they won't be nagged again until 3.0.

**1.x fixes after 2.0 is in the feed.** 1.x installs only read `appcast.xml`, so a separate 1.x feed would only reach 1.x builds released after it exists. The release workflow on the `1.x` branch still replaces the feed with a single item. A 1.x fix published there would take 2.0 out of the feed until the next 2.x release, and it would roll the Homebrew cask on `main` back to 1.x. Options:
- publish 1.x fixes as GitHub releases only, with the appcast and cask steps removed on the `1.x` branch (users download them by hand), or
- make the `1.x` branch workflow write `appcast-1x.xml` and point the 1.x `SUFeedURL` at it in that same fix release. Once that fix is installed, the 1.x install stops seeing 2.0 updates.

A Sparkle channel (`<sparkle:channel>`) would let 1.x and 2.x share one feed. But the 2.0 app would have to ship with `allowedChannels`, and it doesn't yet. Decide before tagging v2.0.0 if you want that.
