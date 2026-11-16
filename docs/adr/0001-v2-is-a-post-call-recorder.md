# v2 is a post-call recorder, not a live copilot

OpenOats 1.x grew into a live meeting copilot (live transcript, suggestions, knowledge base, Sidecast, Ask) at ~46k lines, and its output was mostly low-quality live transcripts nobody re-read. v2 does one job: record a Meeting, then after Stop transcribe the whole tracks and write one markdown file. Nothing is transcribed during the call, so the app is near-idle while recording and loads models only during Processing. In a 10-minute benchmark on a real meeting, whole-file Parakeet v3 fixed the sentence fragmentation and dropped speech of live chunked transcription at ~19 s per 10 min of audio.

## Considered Options

- Refactor 1.x in place: rejected; the complexity is the product surface, not the code style.
- CLI only: rejected; the target user wants an out-of-the-box Mac app. The core stays CLI-drivable for testing.
- Optional live captions: deferred; they keep a model resident for the whole call.

## Consequences

1.x is frozen on a `1.x` branch. Live suggestions, knowledge base, Sidecast, Ask, calendar, webhooks, Apple Notes, Granola import and templates are removed, not hidden. Meeting detection is expected to return in 2.1 as a prompt only.
