# macOS compatibility

OpenOats targets **Apple Silicon, macOS 14.2+**. Core Audio process taps require
14.2; earlier Sonoma releases are not supported. Qwen3 ASR uses macOS 15-only
FluidAudio APIs. Parakeet, Whisper and the existing cloud backends remain
available on Sonoma. Live/batch model pickers and setup detection omit Qwen3
there, and saved unavailable selections resolve to Parakeet v2.

## Building and releasing

Use the existing Xcode 26 / Swift 6.2 build environment on a host supported by
Xcode. The build host's OS is separate from the release app's minimum OS; an
end user on Sonoma only needs the application bundle. Do not lower toolchain
requirements or patch dependency checkouts to produce official releases.

The SwiftPM platform, app Info.plist and UI-test host all target 14.2. Run:

```sh
cd OpenOats
swift test
cd ..
SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
python3 scripts/check_macos_compatibility.py dist/OpenOats.app
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The compatibility check verifies source/bundle deployment metadata and the
executable's Mach-O minimum OS. Package CI runs it on the existing modern
build runner; this is not a substitute for testing a release on Sonoma.

The release workflow reads `LSMinimumSystemVersion` from the built app for
both the Sparkle appcast and the Homebrew cask update. This also preserves the
correct minimum when rebuilding a historical release. The checked-in cask must
continue to describe its currently published binary until a new compatible
release replaces its version and checksum.

## Audio regressions covered

A device-bound tap needs both `deviceUID` and output stream index `0`. On
Sonoma, omitting the stream produced `Stream out of range for tap` in
coreaudiod; tap creation returned success with ID 0 and later format queries
failed with OSStatus 560947818 (`!obj`). Reject an unknown tap ID before
creating its aggregate device. Keep retries for genuinely transient failures.

Streaming conversion uses the capture format's sample rate. The VAD/ASR
consumer may process queued buffers seconds after capture, so its wall-clock
throughput cannot measure the device's rate. The old estimate incorrectly
treated 48 kHz audio as roughly 7–12 kHz on a Sonoma machine. Conversion tests
cover tone frequency/duration, delayed consumption and changes in input format.

For a real-device check in a quiet test session:

1. Enable local audio saving and select the output carrying your playback.
2. Start recording, then mute the microphone in OpenOats.
3. Play a known spoken sentence from another application. Wait for finalized
   text attributed to **Them**; partial hypotheses can take time to settle.
4. Stop and confirm a playable M4A, then restore the microphone. Separately
   verify microphone speech as **You**.
5. Repeat when changing output hardware. Multi-stream professional audio
   interfaces may need a different stream; the first stream is the default.

The underlying audio fixes were verified on macOS 14.6.1 / Apple Silicon with
built-in speakers: a microphone-muted test finalized “The quick brown fox jumps
over the lazy dog.” and saved a 48 kHz mono AAC recording. This is a short
capture/transcription check, not a long-meeting or all-peripherals certification.

For diagnosis, enable Settings → General → Diagnostic logging and inspect the
system-audio events or export diagnostics. Successful startup should report a
nonzero tap ID, a resolved tap format and a successful device start. An absent
permission entry alone does not establish denial if tap creation failed first.
