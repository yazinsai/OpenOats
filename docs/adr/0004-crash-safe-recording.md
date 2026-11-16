# Record uncompressed and resumable so no Meeting is ever lost

A Meeting must survive a crash, force quit, or dead battery mid-call. Tracks are written as raw 16 kHz PCM, flushed every few seconds, into `~/Library/Application Support/OpenOats/Meetings/<meeting>/` alongside a small status file. 1.x wrote to `/tmp` and only produced a playable file on Stop, so an abrupt end left audio nothing recovered and the OS eventually purged. Raw PCM is readable up to the last flush without any container repair, at the cost of ~115 MB/hour/track until Processing compresses it to `.m4a`.

On launch, any Meeting still marked recording or processing is resumed automatically and its Meeting file marked `interrupted: true`. Processing checkpoints each step (per-track transcript, merged Transcript, Notes) and Retry resumes from the last one. Audio is never deleted before a Meeting file exists, and a re-run never overwrites a Meeting file the user has edited.

## Considered Options

- Compressed audio in one file (1.x): unreadable if not closed.
- Compressed 10 s segments: smaller, but many files and the open segment is lost.
