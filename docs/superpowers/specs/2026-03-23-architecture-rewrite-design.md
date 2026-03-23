# OpenOats Architecture Rewrite — Rev 3

## Summary

Incremental top-down extraction of OpenOats from a coordinator-plus-view architecture into a container/controller/repository architecture. Each phase ships as its own PR, CI passes, app is functional after every merge. No phase changes product behavior.

This revision incorporates lessons from the failed Rev 2 attempt (PRs #137–#143, reverted) and Codex review feedback on the Rev 3 draft.

## Why the previous attempt failed

PR #137 collapsed all 8 phases into a single 6,000-line commit. Three specific technical mistakes caused cascading breakage:

1. **Async state transitions**: The original state machine transitions synchronously (`state = .recording` immediately), then dispatches side effects. The rewrite awaited side effects before transitioning, creating unrepresented liminal states and race conditions on rapid toggle.
2. **Hollow controller extraction**: `LiveSessionController` was created but the actual live-session side effects (utterance ingestion, refinement, suggestion triggering, delayed writes, batch polling, settings reactions) remained in `ContentView`. The controller owned nothing meaningful.
3. **One-shot callbacks collapsed to observable state**: Meeting detection uses one-shot notification callbacks (accept/dismiss/timeout). The rewrite modeled these as durable observable state, which either misses or replays events.

## Cross-Cutting Rules

1. **One PR per phase.** CI passes. App is functional after each merge.
2. **No feature changes.** Each phase is structural only. If something needs a feature change, that's a separate PR.
3. **Synchronous state transitions.** The state machine sets state immediately; side effects dispatch async after. No `await` before transitioning phase.
4. **Preserve all implicit contracts.** Map every capability to its new owner before deleting the old owner. Checklist required per phase.
5. **Contract tests before extraction.** Write tests for current behavior before moving it. Tests verify the move didn't break anything.
6. **UI keys off `transcriptionEngine.isRunning` for recording status**, not meeting phase. Do not change this contract.

---

## Phase 0: Contract Tests

**Goal**: Establish a test harness that covers the behavioral contracts about to be moved. Without this, there is no way to verify that subsequent phases preserve behavior.

**What to test** (scoped to what is currently testable through `AppCoordinator`):
- State machine transitions: manual start/stop, auto-detected start/stop, discard, finalization timeout
- Deep link / external command: openNotes routes to correct session
- Finalization pipeline: drain audio → wait pending writes → cleanup → backfill → sidecar → markdown → close files
- Notes generation: generate → save to store → patch markdown file in place
- Session management: rename, delete, cleanup, load transcript

**Deferred to Phase 4** (currently untestable — detection callbacks are private and services are constructed internally):
- Detection flow: accept → session starts, dismiss → no session, timeout → no session, not-a-meeting → bundle ID remembered. `MeetingDetector` and `NotificationService` are constructed inside `setupMeetingDetection()` with no injection point, and all four detection callbacks (`handleDetectionAccepted/NotAMeeting/Dismissed/Timeout`) are private. Phase 4's extraction creates the testing seam — detection contract tests are written there, immediately before moving the code. The "test before move" rule still applies.

**Deferred to Phase 5** (currently untestable — these side effects live in `ContentView`, not in business logic):
- Settings-change reactions (KB folder, notes folder, device ID, API key, transcription model)
- Utterance ingestion pipeline (silence timer + transcript logger + refinement + suggestion + delayed write)
- Batch status polling and auto-dismiss
- MiniBar show/hide on recording state change
- Deep-link start/stop gating: start command rejected when not ready or already running, stop command rejected when not running, notes command always accepted. These guards currently live in `ContentView.handlePendingExternalCommandIfPossible()` and are not testable through the coordinator.

These tests are written as part of their respective phases, immediately before moving the code. The "test before move" rule still applies — it just happens within the same PR for behaviors that are only testable after extraction.

**Approach**: Integration tests that construct a real `AppCoordinator` with mock/stub services (mock `TranscriptionEngine`, in-memory `SessionStore`, etc.). Tests call `handle()` and assert state + side effects.

**What stays the same**: All production code. This phase only adds tests.

**Exit criteria**: Tests pass. No production code changes.

---

## Phase 1: Collapse Service Construction Graph

**Problem**: Services are constructed in three places today:
- `AppRuntime` (line 57+): `TranscriptionEngine`, `SessionStore`, `TranscriptLogger`, `AudioRecorder`, `MeetingDetector`, `CleanupEngine`, `NotesEngine`, `BatchTranscriptionEngine`, `TemplateStore`
- `ContentView` (line 322–331): `KnowledgeBase`, `SuggestionEngine`
- `AppDelegate` / `OpenOatsApp` (line 151+): depends on `runtime.coordinator`

Before introducing `AppContainer`, this split graph must be collapsed so all service construction happens in one place.

**Current state**: `AppRuntime.makeServices()` already constructs `KnowledgeBase` and `SuggestionEngine`, but `ensureServicesInitialized()` never assigns them to the coordinator — they're thrown away. Meanwhile, `ContentView` (lines 322–331) creates its *own* duplicate KB and SE instances stored as `@State`. These duplicates are the ones actually used. This phase eliminates the duplication.

**What changes**:
- `AppRuntime.ensureServicesInitialized()` assigns the KB and SE it already constructs (via `makeServices()`) to the coordinator, so they're accessible to views
- `ContentView` receives KB and SE from the coordinator/runtime instead of creating its own
- Delete the duplicate `@State` KB/SE properties from `ContentView`
- Keep `AppRuntime` as the name for now (rename to `AppContainer` in a later phase when the role fully changes)

**What stays the same**: All behavior. Launch timing. Service lifetimes. The view still polls. Detection still works. Storage untouched.

**Specific contract to preserve**: `KnowledgeBase` and `SuggestionEngine` are currently created lazily on first `ContentView.task` execution. `ensureServicesInitialized()` is called both from the app shell (`OpenOatsApp` line 151) and from `ContentView.task` (line 323). Moving KB/SE into `ensureServicesInitialized()` will create them on whichever call runs first — which may be the app shell call, earlier than the current view-task creation. To preserve current timing, KB/SE construction must remain gated behind the view's `.task` (e.g., a separate `ensureViewServicesInitialized()` called only from the view), OR the earlier creation must be verified safe (KB and SE have no side effects at construction — they only act when methods are called). Verify this during implementation.

**Exit criteria**: No service construction in any View file. Phase 0 tests still pass.

---

## Phase 2: Introduce AppContainer

**What changes**: Rename and reshape `AppRuntime` into `AppContainer` — the single composition root.

- `AppContainer` owns all long-lived services and exposes them as properties
- `OpenOatsApp` creates one `AppContainer` and passes it to scenes
- `AppDelegate` receives the container (not individual services)
- `AppCoordinator` receives services via init instead of constructing them
- `AppContainer` absorbs bootstrap concerns from `AppRuntime`: runtime mode, defaults, directories, UI-test seeding, lazy initialization
- Separate `AppLaunchContext` struct for launch-specific state (first launch, UI test scenario, runtime mode) so the container isn't conflating DI with bootstrap

**What stays the same**: All behavior. Service lifetimes. Initialization order. `AppCoordinator` still owns state machine and all orchestration.

**Exit criteria**: `AppRuntime` deleted. `AppContainer` is the only composition root. Phase 0 tests pass. App launches identically.

---

## Phase 3: Domain Layer Extraction (Narrow Scope)

**What changes**: Move genuinely pure types into `Domain/`. Keep presentation-coupled and persistence-coupled types where they are.

**Moves to `Domain/`**:
- `MeetingState` + `MeetingEvent` + `transition()` (already pure)
- `MeetingMetadata`, `DetectionContext`, `Utterance`, `ConversationState` (pure value types, no framework imports)
- `Speaker` enum (pure, no presentation)

**Stays where it is**:
- `TranscriptStore` — `@MainActor @Observable`, UI-facing. Not a pure domain object.
- `SessionRecord` — persistence DTO (JSONL format). Belongs in persistence layer.
- `SessionIndex`, `SessionSidecar`, `EnhancedNotes` — persistence-coupled types.

**New file**:
- `Views/Speaker+Presentation.swift` — speaker color mapping, display labels (extracted from `Models.swift` if any presentation logic is mixed in)

**Exit criteria**: Nothing in `Domain/` imports SwiftUI, AppKit, or Observation. Phase 0 tests pass.

---

## Phase 4: Extract MeetingDetectionController

**What changes**: Pull detection lifecycle out of `AppCoordinator` into `MeetingDetectionController`.

**Controller owns**:
- `MeetingDetector` lifecycle (setup, teardown)
- `NotificationService` construction and callback wiring
- Sleep observer registration
- Silence timeout monitoring (`noteUtterance()`, timer management)
- Dismissed events tracking (`dismissedEvents` set)
- Detection logging

**Event model**: The controller exposes an `AsyncStream<DetectionEvent>` (not observable state) for one-shot events:
```swift
enum DetectionEvent {
    case accepted(MeetingMetadata)
    case notAMeeting(bundleID: String)
    case dismissed
    case timeout
    case meetingAppExited
    case silenceTimeout
}
```

`AppCoordinator` consumes the stream in a long-lived Task and calls `handle()` for events that should trigger state transitions. This preserves the one-shot callback semantics — events are consumed exactly once, never replayed.

**Stream topology**: `MeetingDetector` already exposes its own `AsyncStream` for detector events. The `MeetingDetectionController` unifies detector events and `NotificationService` callback events into a single `AsyncStream<DetectionEvent>`. The controller uses `AsyncStream.makeStream()` with a continuation, and yields events from both the detector stream and notification callbacks. Buffering policy: `.unbounded` — detection events are infrequent (seconds apart at most) so memory cost is negligible, and no event should ever be silently dropped. (`.bufferingOldest(N)` drops the oldest event when the buffer is full, which contradicts the requirement.)

**NotificationService access**: The controller owns `NotificationService` for detection-related notifications. However, `NotificationService` is also used for batch completion notifications (currently `coordinator.notificationService`). To avoid a cross-controller dependency, `NotificationService` remains accessible via the container as a shared service — the detection controller wires its callbacks, but `LiveSessionController` (Phase 5) can access it for batch completion posting.

**Behavioral gate to preserve**: Today, batch completion notifications only fire if `coordinator.notificationService` exists — which only happens after `setupMeetingDetection()` runs (i.e., detection is enabled). Making `NotificationService` always available via the container would widen this behavior. The container must preserve the gate: `NotificationService` is only constructed when meeting detection is enabled. If detection is disabled, the container's `notificationService` property is nil, and batch completion notifications are silently skipped (matching current behavior).

**Observable state** (for UI binding, separate from events):
- `isEnabled: Bool`
- `detectedApp: MeetingApp?`
- `isMonitoringSilence: Bool`

**What stays the same**: State machine stays in `AppCoordinator`. Views unchanged. Storage unchanged. The coordinator still calls `handle(.userStarted(...))` — it just gets the trigger from the event stream instead of from inline notification callbacks.

**Detection contract tests**: Written at the start of this phase, immediately before moving the code. These were deferred from Phase 0 because the current coordinator has no testing seam for detection (private callbacks, internally constructed services). The extraction itself creates the seam — the controller's `AsyncStream<DetectionEvent>` is the testable surface. Tests cover: accept → session starts, dismiss → no session, timeout → no session, not-a-meeting → bundle ID remembered, meetingAppExited → session stops.

**Exit criteria**: `AppCoordinator` has no direct reference to `MeetingDetector` or `NotificationService`. Detection flow works identically. Detection contract tests pass.

---

## Phase 5: Extract LiveSessionController + Migrate View Side Effects

**Why merged**: Codex correctly identified that extracting `LiveSessionController` without moving ContentView's side effects creates a hollow controller. The live-session side effects (utterance ingestion, transcript logging, refinement, suggestions, delayed writes, batch polling, settings reactions) currently live in `ContentView` lines 371–630. This phase moves them together.

**State machine ownership**: `AppCoordinator` retains ownership of the canonical `MeetingState` property through Phases 4–6. `LiveSessionController` does NOT own a separate copy of the state. Instead, `LiveSessionController` calls methods on `AppCoordinator` (e.g., `coordinator.handle(.userStarted(...))`, `coordinator.handle(.userStopped)`) to trigger state transitions. The coordinator calls `transition()` synchronously and then delegates the async side effects (engine start, session store start, finalization) back to `LiveSessionController`. This avoids the dual-state ambiguity that broke Rev 2. Phase 7 decides where state ultimately lives once the coordinator is hollowed out.

**Controller owns**:
- Session start/stop orchestration (currently `AppCoordinator.handle()` + `ContentView.startSession()`)
- Utterance ingestion: silence timer reset, transcript logger append, refinement trigger, suggestion trigger, delayed JSONL write (currently `ContentView.handleNewUtterance()`)
- Batch status polling and completion handling (currently ContentView's 100ms loop)
- Settings-change reactions: KB folder, notes folder, Voyage API key, transcription model, input device ID (currently `ContentView.synchronizeDerivedState()`)
- Finalization pipeline (currently `AppCoordinator.finalizeCurrentSession()`)
- External command processing for start/stop with readiness and consent gating (openNotes routes through `NotesController` in Phase 6). The current gating in `ContentView.handlePendingExternalCommandIfPossible()` requires engine/logger readiness and `!isRunning` for start, requires `isRunning` for stop, and always accepts notes. These guards must be preserved exactly.

**ContentView side-effect contract tests**: Written at the start of this phase, immediately before moving the code. These test the behaviors that were untestable in Phase 0 (see Phase 0 "Deferred" list), including deep-link start/stop gating. The controller is designed first, tests are written against it, then the side-effect code is moved from `ContentView` into the controller. Tests verify identical behavior.

**State struct** (for view binding):
```swift
struct LiveSessionState {
    var isRunning: Bool          // mirrors transcriptionEngine.isRunning
    var sessionPhase: MeetingState
    var audioLevel: Float        // mirrors transcriptionEngine.audioLevel — drives ControlBar pulse + AudioLevelView and MiniBarContent waveform
    var liveTranscript: [Utterance]
    var volatileYouText: String
    var volatileThemText: String
    var suggestions: [Suggestion]
    var isGeneratingSuggestions: Bool
    var batchStatus: BatchStatus
    var lastEndedSession: String?
    var lastSessionHasNotes: Bool
    var kbIndexingProgress: String
    var statusMessage: String?
    var errorMessage: String?
    var needsDownload: Bool
    var transcriptionPrompt: String?
    var modelDisplayName: String
}
```

**Polling**: The 100ms loop moves from `ContentView` into the controller. The controller runs its own `Task` that polls `transcriptionEngine.isRunning`, `transcriptionEngine.audioLevel`, batch engine status, settings changes, and publishes updated `LiveSessionState`. `ContentView` observes the controller's state — no more `refreshViewState()` or `synchronizeDerivedState()` in the view.

**Critical contract — synchronous transitions**: `startSession()` sets `sessionPhase = .recording` synchronously via the existing `transition()` function, then dispatches async side effects. No `await` before the phase change. No new "error state" — if engine start fails, `transcriptionEngine.isRunning` stays false (which is what the UI reads), and the error surfaces via `errorMessage`. This matches current behavior exactly.

**Critical contract — `isRunning` source**: The view reads `state.isRunning` which mirrors `transcriptionEngine.isRunning`. The controller does NOT use `sessionPhase` to determine recording status for the UI. This preserves the existing contract where `TranscriptionEngine` independently flips `isRunning` during startup/failure.

**What `ContentView` becomes**: A projection of `LiveSessionController.state`. View-local state stays (scroll position, animation, overlay/minibar manager, onboarding). All service references, `handleNewUtterance()`, `synchronizeDerivedState()`, `refreshViewState()`, batch polling, and settings observation are removed.

**What stays the same**: Storage layer (`SessionStore`, `TranscriptLogger`). `NotesView` unchanged (Phase 6). State machine logic (pure `transition()` function) unchanged — the coordinator still calls it. The controller triggers transitions by calling `coordinator.handle()`, never by calling `transition()` directly.

**Exit criteria**: `ContentView` has zero business logic. No service construction, no side effects, no polling. Phase 0 live-session and settings-reaction tests pass. Recording flow works identically.

---

## Phase 6: Extract NotesController + Rewire NotesView

**Controller owns**:
- Session list loading from `SessionStore`
- Selected session state (load transcript, load notes)
- Notes generation (delegates to `NotesEngine`)
- Markdown file patching after notes generation (`MarkdownMeetingWriter.insertLLMSections`)
- Transcript cleanup (delegates to `CleanupEngine`)
- Rename/delete session operations
- Template selection for generation
- External command: openNotes(sessionID) routing
- Original/cleaned transcript toggle

**State struct**:
```swift
struct NotesState {
    var sessionHistory: [SessionIndex]
    var selectedSessionID: String?
    var loadedTranscript: [SessionRecord]
    var loadedNotes: EnhancedNotes?
    var notesGenerationStatus: GenerationStatus
    var cleanupStatus: CleanupStatus
    var selectedTemplate: MeetingTemplate?
    var showingOriginal: Bool
}

enum CleanupStatus {
    case idle
    case inProgress(completed: Int, total: Int)
    case completed
    case error(String)
}

enum GenerationStatus {
    case idle
    case generating
    case completed
    case error(String)
}
```

`NotesView` reads ONLY `NotesState.cleanupStatus` and `NotesState.notesGenerationStatus` — it does not observe `CleanupEngine` or `NotesEngine` directly. The controller maps engine state to these enums in its polling/observation loop.

**Markdown patch contract**: When notes are generated, the controller calls `MarkdownMeetingWriter.insertLLMSections()` to patch the existing markdown file. This is the current `NotesView` behavior (line 596). The controller preserves this exactly — `MarkdownMeetingWriter` is NOT changed to a pure exporter in this phase. That happens in Phase 7 when storage is rewritten.

**What `NotesView` becomes**: A projection of `NotesController.state`. Selection binding dispatches `notesController.selectSession(id)`. Generate button dispatches `notesController.generateNotes()`. All direct `SessionStore` access, `CleanupEngine` calls, and `TemplateStore` access removed from the view.

**Exit criteria**: `NotesView` has zero business logic. Phase 0 notes tests pass.

---

## Phase 7: Hollow Out AppCoordinator

**What changes**: By this point, `AppCoordinator` has delegated detection to `MeetingDetectionController`, live sessions to `LiveSessionController`, and notes to `NotesController`. What remains is a thin routing layer.

**Assess what's left**:
- If `AppCoordinator` is just forwarding calls between controllers, delete it. Controllers talk to each other through the container or explicit interfaces.
- If there's meaningful cross-cutting coordination (e.g., "stop session when app terminates"), keep it as a slim `AppRouter` or absorb into `AppContainer`.

**Decision is made at implementation time** based on what actually remains after Phases 4–6. The spec does not prescribe the answer.

**Exit criteria**: No dead code in the coordinator layer. All tests pass.

---

## Phase 8: Storage Migration (SessionRepository)

**What changes**: Replace `SessionStore` + `TranscriptLogger` with unified `SessionRepository`. New canonical storage format.

**New directory layout**:
```
sessions/<id>/session.json            (metadata — replaces .meta.json sidecar)
sessions/<id>/transcript.live.jsonl   (streaming transcript — replaces flat .jsonl)
sessions/<id>/transcript.final.jsonl  (post-cleanup, replaces .pre-cleanup.bak flow)
sessions/<id>/notes.md                (rendered notes markdown)
sessions/<id>/notes.meta.json         (notes metadata: template snapshot, generatedAt)
sessions/<id>/audio/*                 (batch recordings — replaces batch/ directory)
```

**Notes metadata**: The current `EnhancedNotes` type stores `template: TemplateSnapshot`, `generatedAt: Date`, and `markdown: String` together in the sidecar JSON. In the new layout, the rendered markdown goes to `notes.md` (human-readable, exportable) and the structured metadata (`template`, `generatedAt`) goes to `notes.meta.json`. `SessionRepository.saveNotes()` writes both files atomically. `SessionRepository.loadSession()` recombines them into `EnhancedNotes` for the controller. Session-level metadata (start time, end time, meeting app, engine, title, utterance count) stays in `session.json`.

**SessionRepository API**:
```swift
actor SessionRepository {
    func listSessions() -> [SessionIndex]
    func loadSession(id: String) -> SessionDetail
    func startSession(config: SessionStartConfig) -> SessionHandle
    func appendLiveUtterance(sessionID: String, utterance: Utterance, metadata: LiveUtteranceMetadata)
    func finalizeSession(sessionID: String, metadata: SessionFinalizeMetadata)
    func saveFinalTranscript(sessionID: String, records: [SessionRecord])
    func saveNotes(sessionID: String, notes: EnhancedNotes)
    func renameSession(sessionID: String, title: String)
    func deleteSession(sessionID: String)
    func exportPlainText(sessionID: String) -> String
}
```

**FileHandle lifetime**: During recording, the repository keeps a `FileHandle` open for `transcript.live.jsonl` for the session lifetime. Not open/close per write (which was a performance regression in the failed attempt).

**Legacy compatibility**: A `LegacySessionReader` reads old flat-file sessions. Legacy sessions are imported lazily: they're readable as-is, but when mutated (rename, delete, generate notes), they're migrated to canonical format first. No eager migration.

**TranscriptLogger absorbed**: Plain-text transcript becomes a derived export (`exportPlainText()`), not a parallel write stream. The repository writes JSONL only during recording.

**notesFolderPath contract**: Today, the user-configured `notesFolderPath` (set in SettingsView, described as "Where meeting transcripts are saved") is where `TranscriptLogger` writes `.txt` files, `MarkdownMeetingWriter` writes `.md` files, and `AudioRecorder` writes `.m4a` files (when `saveAudioRecording` is enabled). The new canonical layout stores everything under `sessions/<id>/` in Application Support. To preserve the existing user-facing contract, the repository must **mirror user-visible artifacts to `notesFolderPath`** at these points:
- **On finalization**: copy `notes.md` and export `plain-text.txt` to the configured folder. If `saveAudioRecording` is enabled, copy/move the `.m4a` file as well.
- **On batch transcription completion**: re-export `notes.md` with the updated transcript section. Today `BatchTranscriptionEngine.patchMarkdownTranscript()` patches the `## Transcript` heading in the existing markdown file after batch processing completes. The repository must regenerate and re-mirror the markdown when `saveFinalTranscript()` is called.
- **On notes generation**: re-export `notes.md` with LLM sections included.

Without this mirroring, the setting becomes meaningless and users lose their expected file-based workflow. This is a behavioral contract, not a feature change — the spec's "no feature changes" rule requires it.

**MarkdownMeetingWriter**: Becomes a pure exporter. Finalization calls `MarkdownMeetingWriter.write(from: SessionDetail)`. Notes generation calls `MarkdownMeetingWriter.write(from: SessionDetail)` again with notes included — full regeneration, not in-place patching. Batch transcript completion calls it a third time with the refined transcript. This is safe now because the markdown file is a derived artifact from repository state, not a primary store. The mirrored copy in `notesFolderPath` is updated on every regeneration.

**Controller updates**: `LiveSessionController` and `NotesController` updated to use `SessionRepository` instead of `SessionStore`. Method signatures change but behavior is identical.

**Live utterance writes remain fire-and-forget**: `Task { await repository.appendLiveUtterance(...) }` — no awaiting on the main actor. The delayed-write aggregation pattern from `SessionStore.appendRecordDelayed` is preserved in the repository. This prevents blocking the UI during recording.

**MarkdownMeetingWriter transition from Phase 6**: In Phase 6, `NotesController` calls `MarkdownMeetingWriter.insertLLMSections()` to patch existing markdown files (preserving current behavior). In this phase, `MarkdownMeetingWriter` becomes a pure exporter. `NotesController` is updated to call `MarkdownMeetingWriter.write(from: SessionDetail)` for full regeneration instead of `insertLLMSections()`. The patching method is then deleted.

**Exit criteria**: New sessions create canonical layout. Legacy sessions readable. Lazy migration works. `SessionStore` and `TranscriptLogger` deleted. All tests pass. Full manual acceptance: record → view notes → generate notes → verify files.

---

## Phase 9: Settings Refactor

**What changes**: Replace monolithic `AppSettings` with typed grouped settings under `SettingsStore`.

**Groups**:
- `AISettings` (LLM provider, model, API keys, suggestion verbosity, refinement toggle)
- `CaptureSettings` (input device, transcription model, VAD sensitivity)
- `DetectionSettings` (enabled apps, custom bundle IDs, silence timeout, detection log)
- `PrivacySettings` (recording consent, data retention)
- `UISettings` (show transcript, mini bar, theme)

**SettingsStore**:
- Owns persistence and migration from current `UserDefaults` keys
- Typed access replaces stringly-typed property access
- Settings-change reactions in controllers observe `SettingsStore` groups directly
- No feature code touches `UserDefaults` after migration

**Swift 6.2 observation workaround**: The current `AppSettings` uses `@ObservationIgnored nonisolated(unsafe)` backing storage to avoid MainActor executor crashes when SwiftUI reads properties during view body evaluation. `SettingsStore` must preserve this workaround — the grouped settings types need the same `nonisolated(unsafe)` backing pattern until Swift adds proper support for `@Observable` on `@MainActor` types read from view bodies. This is not just a type cleanup; the observation model must match the existing workaround or views will crash.

**Migration**: Old keys remain readable. New writes go through `SettingsStore`. Both old and new keys kept in sync during transition (one release cycle), then old keys dropped.

**Exit criteria**: No direct `UserDefaults` access outside `SettingsStore`. Settings view binds to typed groups. No MainActor executor crashes. All tests pass.

---

## Phase 10: Cleanup and Repo Normalization

**What changes**:
- Delete dead code: unused soft-delete paths, duplicate artifact writers, view-owned bootstrap remnants
- Normalize repo root: product code top-level, dev-only artifacts consolidated
- Final audit: no SwiftUI/AppKit imports in Domain, Persistence, or Runtime layers
- Update `CLAUDE.md` project structure section

**Exit criteria**: `swift build` clean. `swift test` clean. No dead code. Clean layer boundaries.

---

## Test Plan (Per-Phase)

| Phase | Required Tests |
|-------|---------------|
| 0 | Contract tests for coordinator-testable behaviors: state machine, finalization, notes, session management (detection deferred to Phase 4 — no testing seam exists) |
| 1 | Phase 0 tests pass. No service construction in views. No duplicate KB/SE instances |
| 2 | Same tests pass. `AppRuntime` deleted |
| 3 | Same tests pass. No framework imports in `Domain/` |
| 4 | Detection contract tests written first (deferred from Phase 0). Detection integration tests via event stream. One-shot semantics verified. Unbounded buffering verified (no dropped events) |
| 5 | Side-effect contract tests written first (including deep-link start/stop gating). Live session integration tests. Manual + auto start/stop. Rapid toggle race test. Settings reactions. Utterance ingestion pipeline. audioLevel propagation |
| 6 | Notes integration tests. Generate → save → markdown patch. Cleanup progress mapping. Rename/delete |
| 7 | Coordinator gone or minimal. All tests pass |
| 8 | Repository CRUD. Legacy read. Lazy migration. FileHandle lifetime. Fire-and-forget writes. notesFolderPath mirroring on finalize and notes generation. Full recording flow |
| 9 | Settings migration round-trip. Typed access. No raw UserDefaults |
| 10 | Clean build. Clean layers. Manual acceptance |

## Manual Acceptance (After Each Phase)

- App launches without crash
- Manual start/stop recording works
- Auto-detection prompts and starts session
- Silence timeout stops session
- Notes window opens, loads history, shows transcript
- Notes generation produces markdown
- Batch transcription completes and refreshes
- Settings changes take effect during and between sessions
- Deep link opens correct session in notes
- Legacy sessions remain visible and openable
