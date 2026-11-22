# Meeting detection asks about the app on the mic, backed by speakers or camera

2.1 brings back meeting detection as a "Record this meeting?" prompt. A Call is detected when one Call app (Zoom, Teams, FaceTime, Slack, a browser, …) is itself recording from the mic for 5 seconds while it also plays audio or a camera is on. The mic and speaker state per process come from Core Audio (macOS 14); the camera state from CoreMediaIO. It ends when that app has left the mic alone for 20 seconds. One prompt per Call, withdrawn when the Call ends or any recording starts; a recording started from the prompt stops when its Call ends.

1.x asked "is any mic running?" and "is a meeting app open?" and joined the answers. That one shortcut caused most of its noise:

- A dictation app holding the mic while WhatsApp sat open was a "WhatsApp meeting" (#726: 11 false recordings in 45 minutes). The fix was a list of dictation apps to ignore, which kept growing (Superwhisper, Wispr Flow, MacWhisper, VoiceInk, Claude, Codex, Gemini, …).
- The prompt named whichever meeting app was open, not the one on the call: a Meet tab in Brave was reported as Teams (#643).
- Browsers couldn't be listed, because any site using the mic would have prompted, so browser calls went undetected (#187).
- "Ignore This App" was the only escape from a false positive, and ignoring WhatsApp also lost real WhatsApp calls.
- The camera alone also triggered a prompt. CoreMediaIO says a camera is running, not which process has it, so camera prompts named whichever meeting app was open (#657), and Photo Booth or a camera check prompted too.
- Auto-stop leaned on silence, and a fixed silence threshold below any real mic's noise floor left recordings running for days.

Asking which process holds the mic, and requiring that same app to also play audio, removes each of these at the source. The camera stays as backup evidence only: it stands in for the speakers when a Call app holds the mic but its output isn't attributed to it (a muted call, output routed through another process), and it never starts a Call on its own. dictation apps and voice notes are one-way, the named app is the one doing the audio, and browsers become safe to include. The allowlist names Call apps; nothing needs to be ignored by default. "Don't Ask for <app>" stays, now meaning only that app's real Calls. The end of a Call is the app releasing the mic, not silence.

## Considered Options

- Keep 1.x's mic + running-app rule with a bigger dictation denylist: rejected, it can't name the right app or cover browsers.
- Camera as a trigger on its own (1.x): rejected; it can't say which app, and every video call also uses the mic, so it adds noise without finding Calls the mic misses.
- Calendar events as a trigger: out of scope (calendars name Meetings instead, ADR 0006).
- Record automatically: rejected; a prompt costs one click, a false recording costs the user's trust.
- Polling the process list all the time: rejected for idle cost; input devices' running state wakes the watcher, and it samples every 2 s only while some mic is in use.

## Consequences

`CallDetector` (OatsCore) is pure and unit-tested; `CallWatcher` (OatsCapture) feeds it. `oats calls` prints what detection sees, so a missed app is a one-line addition to `CallApp.known` from a user's output. A browser tab that both records and plays (a voice assistant, a mic test), or records while any camera is on (a Loom-style recording), can still prompt once; "not now" is ignoring the notification. Recordings started without the prompt never stop by themselves.
