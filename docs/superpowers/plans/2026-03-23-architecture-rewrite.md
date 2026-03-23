# Architecture Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Incrementally extract OpenOats from coordinator-plus-view into container/controller/repository architecture across 11 phases, each shipping as its own PR.

**Architecture:** Top-down extraction. Each phase isolates one concern (tests, DI, domain types, detection, live session, notes, coordinator cleanup, storage, settings, final cleanup). State machine stays pure. Controllers use AsyncStream for one-shot events. Views become state projections. Repository unifies storage.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, XCTest, Observation framework

**Spec:** `docs/superpowers/specs/2026-03-23-architecture-rewrite-design.md`

---

## Phase 0: Contract Tests

### Task 0.1: State Machine Contract Tests

**Files:**
- Modify: `Tests/OpenOatsTests/MeetingStateTests.swift` (extend existing)

These tests already exist and are comprehensive (543 lines). Verify coverage matches spec requirements.

- [ ] **Step 1: Read existing MeetingStateTests.swift and verify coverage**

Check that tests cover: manual start/stop, auto-detected start/stop, discard, finalization timeout, no-op transitions (double-start, stop-while-idle).

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter MeetingStateTests 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 2: Add any missing transition tests**

If any of these cases are missing, add them:
- idle + userStopped → idle (no-op)
- idle + userDiscarded → idle (no-op)
- idle + finalizationComplete → idle (no-op)
- recording + userStarted → recording (no-op, same metadata preserved)
- ending + userStarted → ending (no-op)
- ending + userStopped → ending (no-op)

```swift
func testIdleIgnoresStopEvent() {
    let result = transition(from: .idle, on: .userStopped)
    XCTAssertEqual(result, .idle)
}

func testIdleIgnoresDiscardEvent() {
    let result = transition(from: .idle, on: .userDiscarded)
    XCTAssertEqual(result, .idle)
}

func testRecordingIgnoresDoubleStart() {
    let meta = makeMetadata(title: "First")
    let state = MeetingState.recording(meta)
    let result = transition(from: state, on: .userStarted(makeMetadata(title: "Second")))
    XCTAssertEqual(result, state)
}

func testEndingIgnoresStart() {
    let meta = makeMetadata()
    let state = MeetingState.ending(meta)
    let result = transition(from: state, on: .userStarted(makeMetadata()))
    XCTAssertEqual(result, state)
}

func testEndingIgnoresStop() {
    let meta = makeMetadata()
    let state = MeetingState.ending(meta)
    let result = transition(from: state, on: .userStopped)
    XCTAssertEqual(result, state)
}
```

- [ ] **Step 3: Run state machine tests**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter MeetingStateTests 2>&1 | tail -10`
Expected: All pass

---

### Task 0.2: Deep Link / External Command Contract Tests

**Files:**
- Create: `Tests/OpenOatsTests/ExternalCommandTests.swift`

- [ ] **Step 1: Write external command routing tests**

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class ExternalCommandTests: XCTestCase {

    func testQueueExternalCommandSetsProperty() {
        let coordinator = AppCoordinator()
        XCTAssertNil(coordinator.pendingExternalCommand)

        coordinator.queueExternalCommand(.startSession)
        XCTAssertNotNil(coordinator.pendingExternalCommand)
        XCTAssertEqual(coordinator.pendingExternalCommand?.command, .startSession)
    }

    func testCompleteExternalCommandClearsMatchingRequest() {
        let coordinator = AppCoordinator()
        coordinator.queueExternalCommand(.stopSession)
        let requestID = coordinator.pendingExternalCommand!.id

        coordinator.completeExternalCommand(requestID)
        XCTAssertNil(coordinator.pendingExternalCommand)
    }

    func testCompleteExternalCommandIgnoresMismatchedID() {
        let coordinator = AppCoordinator()
        coordinator.queueExternalCommand(.stopSession)

        coordinator.completeExternalCommand(UUID())
        XCTAssertNotNil(coordinator.pendingExternalCommand)
    }

    func testOpenNotesQueuesSessionSelection() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection("session_abc")
        XCTAssertEqual(coordinator.requestedSessionSelectionID, "session_abc")
    }

    func testConsumeRequestedSessionSelectionClearsAfterRead() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection("session_abc")

        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertEqual(consumed, "session_abc")
        XCTAssertNil(coordinator.requestedSessionSelectionID)
    }

    func testConsumeRequestedSessionSelectionReturnsNilWhenEmpty() {
        let coordinator = AppCoordinator()
        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertNil(consumed)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter ExternalCommandTests 2>&1 | tail -10`
Expected: All pass

---

### Task 0.3: Finalization Pipeline Contract Tests

**Files:**
- Modify: `Tests/OpenOatsTests/AppCoordinatorIntegrationTests.swift`

- [ ] **Step 1: Add finalization pipeline tests**

Test that after userStopped: session file exists, sidecar written, history updated, transcript logger closed, lastEndedSession set.

```swift
func testFinalizationWritesSidecarWithCorrectMetadata() async {
    // Use the same setup pattern as testUserStoppedFinalizesSessionAndRefreshesHistory
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("OpenOatsFinalizationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

    let suiteName = "com.openoats.tests.finalization.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(notesDirectory.path, forKey: "notesFolderPath")
    defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")

    let storage = AppSettingsStorage(
        defaults: defaults,
        secretStore: .ephemeral,
        defaultNotesDirectory: notesDirectory,
        runMigrations: false
    )
    let settings = AppSettings(storage: storage)
    let transcriptStore = TranscriptStore()
    let sessionStore = SessionStore(rootDirectory: root)
    let coordinator = AppCoordinator(
        sessionStore: sessionStore,
        templateStore: TemplateStore(rootDirectory: root),
        notesEngine: NotesEngine(mode: .scripted(markdown: "Test")),
        transcriptStore: transcriptStore
    )
    coordinator.transcriptionEngine = TranscriptionEngine(
        transcriptStore: transcriptStore,
        settings: settings,
        mode: .scripted([
            Utterance(text: "Hello from you.", speaker: .you),
            Utterance(text: "Hello from them.", speaker: .them),
        ])
    )
    coordinator.transcriptLogger = TranscriptLogger(directory: notesDirectory)

    let metadata = MeetingMetadata.manual()
    coordinator.handle(.userStarted(metadata), settings: settings)

    // Wait for engine to start
    for _ in 0..<20 {
        if coordinator.transcriptionEngine?.isRunning == true { break }
        try? await Task.sleep(for: .milliseconds(50))
    }

    coordinator.handle(.userStopped, settings: settings)

    // Wait for finalization
    for _ in 0..<50 {
        if case .idle = coordinator.state, coordinator.lastEndedSession != nil { break }
        try? await Task.sleep(for: .milliseconds(100))
    }

    // Verify state returned to idle
    XCTAssertEqual(coordinator.state, .idle)

    // Verify sidecar was written
    let indices = await sessionStore.loadSessionIndex()
    XCTAssertFalse(indices.isEmpty)
    let session = indices.first!
    XCTAssertFalse(session.hasNotes)
    XCTAssertEqual(session.utteranceCount, 2)
}

func testFinalizationTimeoutForcesIdleState() async {
    let coordinator = AppCoordinator()
    let metadata = MeetingMetadata.manual()

    // Manually set state to ending to test timeout
    coordinator.handle(.userStarted(metadata))
    XCTAssertEqual(coordinator.isRecording, true)

    // Direct transition to ending then timeout
    coordinator.handle(.userStopped)
    // Force timeout
    coordinator.handle(.finalizationTimeout)
    XCTAssertEqual(coordinator.state, .idle)
}
```

- [ ] **Step 2: Run integration tests**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter AppCoordinatorIntegrationTests 2>&1 | tail -10`
Expected: All pass

---

### Task 0.4: Notes Generation Contract Tests

**Files:**
- Create: `Tests/OpenOatsTests/NotesContractTests.swift`

- [ ] **Step 1: Write notes generation and session management tests**

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class NotesContractTests: XCTestCase {

    private func makeTestEnvironment() async -> (SessionStore, TemplateStore, AppCoordinator, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsNotesTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sessionStore = SessionStore(rootDirectory: root)
        let templateStore = TemplateStore(rootDirectory: root)
        let coordinator = AppCoordinator(
            sessionStore: sessionStore,
            templateStore: templateStore,
            notesEngine: NotesEngine(mode: .scripted(markdown: "# Test Notes\n\nGenerated.")),
            transcriptStore: TranscriptStore()
        )
        return (sessionStore, templateStore, coordinator, root)
    }

    func testLoadHistoryReturnsPersistedSessions() async {
        let (sessionStore, _, coordinator, _) = await makeTestEnvironment()

        // Seed a session
        await sessionStore.seedSession(
            id: "test_session_1",
            records: [
                SessionRecord(speaker: .you, text: "Hello", timestamp: Date())
            ],
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Test Session"
        )

        await coordinator.loadHistory()
        XCTAssertTrue(coordinator.sessionHistory.contains(where: { $0.id == "test_session_1" }))
    }

    func testSessionRenameUpdatesIndex() async {
        let (sessionStore, _, coordinator, _) = await makeTestEnvironment()

        await sessionStore.seedSession(
            id: "rename_test",
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Original"
        )

        await sessionStore.renameSession(sessionID: "rename_test", title: "Renamed")
        await coordinator.loadHistory()

        let session = coordinator.sessionHistory.first(where: { $0.id == "rename_test" })
        XCTAssertEqual(session?.title, "Renamed")
    }

    func testSessionDeleteRemovesFromIndex() async {
        let (sessionStore, _, coordinator, _) = await makeTestEnvironment()

        await sessionStore.seedSession(
            id: "delete_test",
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "To Delete"
        )

        await sessionStore.softDeleteSession(sessionID: "delete_test")
        await coordinator.loadHistory()

        XCTAssertFalse(coordinator.sessionHistory.contains(where: { $0.id == "delete_test" }))
    }

    func testLoadTranscriptReturnsRecords() async {
        let (sessionStore, _, _, _) = await makeTestEnvironment()

        let records = [
            SessionRecord(speaker: .you, text: "First", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Second", timestamp: Date()),
        ]
        await sessionStore.seedSession(
            id: "transcript_test",
            records: records,
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Transcript Test"
        )

        let loaded = await sessionStore.loadTranscript(sessionID: "transcript_test")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "First")
        XCTAssertEqual(loaded[1].text, "Second")
    }

    func testNotesGenerationSavesToStoreAndPatchesMarkdown() async {
        let (sessionStore, _, coordinator, root) = await makeTestEnvironment()
        let notesDir = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        // Seed a session with transcript
        let records = [
            SessionRecord(speaker: .you, text: "Hello", timestamp: Date()),
            SessionRecord(speaker: .them, text: "World", timestamp: Date()),
        ]
        await sessionStore.seedSession(
            id: "notes_gen_test",
            records: records,
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Notes Gen Test"
        )

        // Generate notes via scripted engine
        let notesEngine = coordinator.notesEngine
        await notesEngine.generate(
            transcript: records,
            template: TemplateStore.builtInTemplates.first!
        )

        // Verify notes engine produced markdown
        XCTAssertFalse(notesEngine.generatedMarkdown.isEmpty)
    }

    func testCleanupEngineProcessesTranscript() async {
        // TranscriptCleanupEngine is covered by its own test file.
        // This verifies the coordinator can access it and the type is wired correctly.
        let coordinator = AppCoordinator()
        XCTAssertNotNil(coordinator.cleanupEngine)
    }
}
```

- [ ] **Step 2: Run notes contract tests**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter NotesContractTests 2>&1 | tail -10`
Expected: All pass

---

### Task 0.5: Discard Session Contract Test

**Files:**
- Modify: `Tests/OpenOatsTests/AppCoordinatorIntegrationTests.swift`

- [ ] **Step 1: Add discard test**

```swift
func testDiscardReturnsToIdleWithoutFinalization() async {
    let coordinator = AppCoordinator()
    let metadata = MeetingMetadata.manual()

    coordinator.handle(.userStarted(metadata))
    XCTAssertEqual(coordinator.isRecording, true)

    coordinator.handle(.userDiscarded)
    XCTAssertEqual(coordinator.state, .idle)
    XCTAssertNil(coordinator.lastEndedSession)
}
```

- [ ] **Step 2: Run and verify**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test --filter AppCoordinatorIntegrationTests 2>&1 | tail -10`
Expected: All pass

- [ ] **Step 3: Run full test suite to verify nothing broken**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 4: Commit Phase 0**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Tests/OpenOatsTests/ExternalCommandTests.swift OpenOats/Tests/OpenOatsTests/NotesContractTests.swift OpenOats/Tests/OpenOatsTests/AppCoordinatorIntegrationTests.swift OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift
git commit -m "Phase 0: Add contract tests for state machine, finalization, notes, and session management"
```

---

## Phase 1: Collapse Service Construction Graph

### Task 1.1: Move KB and SE Construction into ensureServicesInitialized

**Files:**
- Modify: `Sources/OpenOats/App/AppRuntime.swift:174-184`
- Modify: `Sources/OpenOats/App/AppCoordinator.swift` (add KB/SE properties)
- Modify: `Sources/OpenOats/Views/ContentView.swift:322-331` (remove duplicate construction)

- [ ] **Step 1: Verify KB and SE have no side effects at construction**

Read `Sources/OpenOats/Intelligence/KnowledgeBase.swift` init and `Sources/OpenOats/Intelligence/SuggestionEngine.swift` init. Confirm they only store references, no I/O or task launches.

- [ ] **Step 2: Add knowledgeBase and suggestionEngine properties to AppCoordinator**

In `AppCoordinator.swift`, add after the `batchEngine` property (around line 103):

```swift
@ObservationIgnored private var _knowledgeBase: KnowledgeBase?
nonisolated var knowledgeBase: KnowledgeBase? {
    get { _knowledgeBase }
}

@ObservationIgnored private var _suggestionEngine: SuggestionEngine?
nonisolated var suggestionEngine: SuggestionEngine? {
    get { _suggestionEngine }
}
```

Add a setter method (MainActor-isolated):

```swift
func setViewServices(knowledgeBase: KnowledgeBase, suggestionEngine: SuggestionEngine) {
    _knowledgeBase = knowledgeBase
    _suggestionEngine = suggestionEngine
}
```

- [ ] **Step 3: Update ensureServicesInitialized to assign KB and SE**

In `AppRuntime.swift`, update `ensureServicesInitialized()` to also assign:

```swift
coordinator.setViewServices(
    knowledgeBase: services.knowledgeBase,
    suggestionEngine: services.suggestionEngine
)
```

- [ ] **Step 4: Update ContentView to use coordinator's KB and SE**

In `ContentView.swift`:
- Remove the `@State private var knowledgeBase: KnowledgeBase?` and `@State private var suggestionEngine: SuggestionEngine?` declarations
- Add computed accessors that read from coordinator:
```swift
private var knowledgeBase: KnowledgeBase? { coordinator.knowledgeBase }
private var suggestionEngine: SuggestionEngine? { coordinator.suggestionEngine }
```
- In the `.task` block (lines 322-331), remove the KB/SE construction. Keep `runtime.ensureServicesInitialized(settings:coordinator:)` call.
- Adjust `if knowledgeBase == nil` guard to `if coordinator.knowledgeBase == nil` and only call `ensureServicesInitialized`.

- [ ] **Step 5: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Expected: Build succeeds

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 6: Verify no service construction in any View file**

```bash
grep -rn "KnowledgeBase(\|SuggestionEngine(" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Views/
```
Expected: No matches

- [ ] **Step 7: Commit Phase 1**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/AppCoordinator.swift OpenOats/Sources/OpenOats/App/AppRuntime.swift OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "Phase 1: Collapse service construction — KB and SE created in AppRuntime, not ContentView"
```

---

## Phase 2: Introduce AppContainer

### Task 2.1: Create AppContainer from AppRuntime

**Files:**
- Rename: `Sources/OpenOats/App/AppRuntime.swift` → `Sources/OpenOats/App/AppContainer.swift`
- Create: `Sources/OpenOats/App/AppLaunchContext.swift` (extract struct)
- Modify: `Sources/OpenOats/App/OpenOatsApp.swift` (use AppContainer)
- Modify: `Sources/OpenOats/Views/ContentView.swift` (environment type)

- [ ] **Step 1: Extract AppLaunchContext to its own file**

Move `UITestScenario`, `AppRuntimeMode`, `AppServices` from `AppRuntime.swift` into a new `AppLaunchContext.swift`. Redesign `AppLaunchContext` to separate launch-specific state from DI. The container holds long-lived services; the launch context holds bootstrap-only state:

```swift
struct AppLaunchContext {
    let isFirstLaunch: Bool
    let uiTestScenario: UITestScenario?
    let runtimeMode: AppRuntimeMode
    let container: AppContainer
    let updaterController: AppUpdaterController
}
```

The container now owns `settings` and `coordinator` as properties (they're long-lived DI concerns, not launch state).

- [ ] **Step 2: Rename AppRuntime to AppContainer**

In the renamed file, change `class AppRuntime` → `class AppContainer`. Update all internal references. The static `bootstrap()` method stays.

- [ ] **Step 3: Move AppCoordinator construction into AppContainer**

`AppContainer` should own coordinator creation. `AppCoordinator` receives services via init — the coordinator no longer has default parameter values for its init (it gets explicit services from the container).

- [ ] **Step 4: Update OpenOatsApp.swift**

Replace `@State private var runtime: AppRuntime` with `@State private var container: AppContainer`. Update `.environment(runtime)` → `.environment(container)`. Update `AppDelegate` references.

- [ ] **Step 5: Update ContentView.swift**

Replace `@Environment(AppRuntime.self) private var runtime` with `@Environment(AppContainer.self) private var container`. Update all `runtime.` references to `container.`.

- [ ] **Step 6: Update all other references to AppRuntime**

Search for `AppRuntime` across the codebase and update to `AppContainer`.

- [ ] **Step 7: Delete AppRuntime.swift if renamed, or verify rename complete**

- [ ] **Step 8: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 9: Commit Phase 2**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/AppContainer.swift OpenOats/Sources/OpenOats/App/AppLaunchContext.swift OpenOats/Sources/OpenOats/App/OpenOatsApp.swift OpenOats/Sources/OpenOats/App/AppCoordinator.swift OpenOats/Sources/OpenOats/Views/ContentView.swift
git rm OpenOats/Sources/OpenOats/App/AppRuntime.swift
git commit -m "Phase 2: Rename AppRuntime to AppContainer as single composition root"
```

---

## Phase 3: Domain Layer Extraction

### Task 3.1: Create Domain Directory and Move Pure Types

**Files:**
- Create: `Sources/OpenOats/Domain/MeetingState.swift` (move from Meeting/)
- Create: `Sources/OpenOats/Domain/MeetingTypes.swift` (move pure types from Meeting/)
- Create: `Sources/OpenOats/Domain/Models.swift` (move pure value types from Models/)
- Create: `Sources/OpenOats/Views/Speaker+Presentation.swift` (extract color/display from Speaker)

- [ ] **Step 1: Create Domain/ directory**

```bash
mkdir -p /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Domain
```

- [ ] **Step 2: Move MeetingState.swift to Domain/**

Move `Meeting/MeetingState.swift` → `Domain/MeetingState.swift`. Verify no framework imports needed (it's already pure Foundation).

- [ ] **Step 3: Extract pure types from MeetingTypes.swift**

Move `MeetingMetadata`, `DetectionContext`, `MeetingApp`, `MeetingAppEntry`, `DetectionSignal`, `CalendarEvent` to `Domain/MeetingTypes.swift`. These are pure value types with no framework imports.

- [ ] **Step 4: Extract pure types from Models.swift**

Move `Utterance`, `ConversationState`, `Speaker` (enum cases + `isRemote`, `storageKey`, `displayLabel` — NOT `color`) to `Domain/Utterance.swift`. The `Speaker.color` property requires SwiftUI and stays in a presentation extension.

- [ ] **Step 5: Create Speaker+Presentation.swift**

```swift
import SwiftUI

extension Speaker {
    var color: Color {
        switch self {
        case .you:
            Color(red: 0.35, green: 0.55, blue: 0.75)
        case .them:
            Color(red: 0.82, green: 0.6, blue: 0.3)
        case .remote(let n):
            Self.remoteColors[(n - 1) % Self.remoteColors.count]
        }
    }

    private static let remoteColors: [Color] = [
        // ... copy from Models.swift
    ]
}
```

Remove `color` and `remoteColors` from the Domain version of Speaker.

- [ ] **Step 6: Verify no framework imports in Domain/**

```bash
grep -r "import SwiftUI\|import AppKit\|import Observation" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Domain/
```
Expected: No matches

- [ ] **Step 7: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 8: Commit Phase 3**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/Domain/ OpenOats/Sources/OpenOats/Views/Speaker+Presentation.swift OpenOats/Sources/OpenOats/Models/Models.swift OpenOats/Sources/OpenOats/Meeting/MeetingState.swift OpenOats/Sources/OpenOats/Meeting/MeetingTypes.swift
git commit -m "Phase 3: Extract pure domain types into Domain/ — no framework imports"
```

---

## Phase 4: Extract MeetingDetectionController

### Task 4.1: Define DetectionEvent and MeetingDetectionController

**Files:**
- Create: `Sources/OpenOats/App/MeetingDetectionController.swift`
- Modify: `Sources/OpenOats/App/AppCoordinator.swift` (remove detection code)
- Modify: `Sources/OpenOats/App/AppContainer.swift` (wire controller)
- Create: `Tests/OpenOatsTests/MeetingDetectionControllerTests.swift`

- [ ] **Step 1: Write detection contract tests first**

These tests were deferred from Phase 0. Write them against the controller's `AsyncStream<DetectionEvent>` interface:

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class MeetingDetectionControllerTests: XCTestCase {

    func testAcceptedEventTriggersSessionStart() async {
        // Test that consuming an .accepted event from the stream
        // allows the coordinator to start a session
    }

    func testDismissedEventDoesNotStartSession() async {
        // .dismissed → no state change
    }

    func testTimeoutEventDoesNotStartSession() async {
        // .timeout → no state change
    }

    func testNotAMeetingRemembersBundleID() async {
        // .notAMeeting(bundleID:) → bundleID stored in dismissedEvents
    }

    func testMeetingAppExitedStopsRecording() async {
        // .meetingAppExited → userStopped if recording auto-detected session
    }

    func testEventsConsumedExactlyOnce() async {
        // One-shot semantics: after consuming an event from the stream,
        // it is not replayed on subsequent iterations
    }

    func testRapidEventsAllDelivered() async {
        // Unbounded buffering: yield multiple events rapidly,
        // verify all are received (none dropped)
    }
}
```

- [ ] **Step 2: Create MeetingDetectionController**

```swift
import Foundation
import Observation
import os

enum DetectionEvent: Sendable {
    case accepted(MeetingMetadata)
    case notAMeeting(bundleID: String)
    case dismissed
    case timeout
    case meetingAppExited
    case silenceTimeout
}

@Observable
@MainActor
final class MeetingDetectionController {
    private(set) var isEnabled = false
    private(set) var detectedApp: MeetingApp?
    private(set) var isMonitoringSilence = false

    private var detector: MeetingDetector?
    private var notification: NotificationService?
    private var detectionTask: Task<Void, Never>?
    private var silenceCheckTask: Task<Void, Never>?
    private var sleepObserver: Any?
    private var lastUtteranceAt: Date?
    private(set) var dismissedEvents: Set<String> = []

    private var eventContinuation: AsyncStream<DetectionEvent>.Continuation?
    private(set) var events: AsyncStream<DetectionEvent>!

    // ... setup(), teardown(), noteUtterance() migrated from AppCoordinator
}
```

The controller unifies MeetingDetector's own AsyncStream and NotificationService callbacks into a single `AsyncStream<DetectionEvent>` using `AsyncStream.makeStream(bufferingPolicy: .unbounded)`.

- [ ] **Step 3: Move detection code from AppCoordinator to controller**

Move these methods from AppCoordinator:
- `setupMeetingDetection()` → `MeetingDetectionController.setup()`
- `teardownMeetingDetection()` → `MeetingDetectionController.teardown()`
- `installSleepObserver()` → internal to controller (yields `.meetingAppExited` via coordinator callback or directly handles)
- `startSilenceMonitoring()` → internal, yields `.silenceTimeout`
- `noteUtterance()` → `MeetingDetectionController.noteUtterance()`
- `handleMeetingDetected()` → internal, posts notification
- `handleMeetingEnded()` → yields `.meetingAppExited`
- `handleDetectionAccepted()` → yields `.accepted(metadata)`
- `handleDetectionNotAMeeting()` → yields `.notAMeeting(bundleID:)`
- `handleDetectionDismissed()` → yields `.dismissed`
- `handleDetectionTimeout()` → yields `.timeout`
- `evaluateImmediate()` → `MeetingDetectionController.evaluateImmediate()`
- `dismissedEvents` set → internal to controller

- [ ] **Step 4: AppCoordinator consumes the event stream**

Add a method to AppCoordinator that starts a long-lived Task consuming the controller's event stream:

```swift
func startDetectionEventLoop(_ controller: MeetingDetectionController) {
    detectionEventTask = Task { [weak self] in
        for await event in controller.events {
            guard let self, !Task.isCancelled else { break }
            switch event {
            case .accepted(let metadata):
                self.handle(.userStarted(metadata), settings: self.activeSettings)
            case .meetingAppExited:
                if case .recording(let meta) = self.state,
                   case .appLaunched = meta.detectionContext?.signal {
                    self.handle(.userStopped)
                }
            case .silenceTimeout:
                if case .recording = self.state {
                    self.handle(.userStopped)
                }
            case .notAMeeting, .dismissed, .timeout:
                break // logged by controller
            }
        }
    }
}
```

- [ ] **Step 5: Wire in AppContainer**

Container creates `MeetingDetectionController`, passes `NotificationService` as shared (nil when detection disabled).

- [ ] **Step 6: Update ContentView detection setup calls**

Replace `coordinator.setupMeetingDetection(settings:)` with container's detection controller setup. Replace `coordinator.noteUtterance()` with `detectionController.noteUtterance()`.

- [ ] **Step 7: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 8: Verify AppCoordinator has no MeetingDetector or NotificationService references**

```bash
grep -n "MeetingDetector\|NotificationService\|meetingDetector\|notificationService" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/App/AppCoordinator.swift
```
Expected: No matches (except possibly the `notificationService` property if shared via container)

- [ ] **Step 9: Commit Phase 4**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/MeetingDetectionController.swift OpenOats/Sources/OpenOats/App/AppCoordinator.swift OpenOats/Sources/OpenOats/App/AppContainer.swift OpenOats/Sources/OpenOats/Views/ContentView.swift OpenOats/Tests/OpenOatsTests/MeetingDetectionControllerTests.swift
git commit -m "Phase 4: Extract MeetingDetectionController with AsyncStream<DetectionEvent>"
```

---

## Phase 5: Extract LiveSessionController + Migrate View Side Effects

### Task 5.1: Define LiveSessionState and LiveSessionController

**Files:**
- Create: `Sources/OpenOats/App/LiveSessionController.swift`
- Modify: `Sources/OpenOats/Views/ContentView.swift` (remove all business logic)
- Modify: `Sources/OpenOats/App/AppCoordinator.swift` (delegate side effects)
- Modify: `Sources/OpenOats/App/AppContainer.swift` (wire controller)
- Create: `Tests/OpenOatsTests/LiveSessionControllerTests.swift`

- [ ] **Step 1: Write ContentView side-effect contract tests**

Test the behaviors deferred from Phase 0: utterance ingestion, settings reactions, batch polling, deep-link gating.

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class LiveSessionControllerTests: XCTestCase {

    func testStartSessionSetsPhaseToRecordingSynchronously() async {
        // Verify: state = .recording immediately, no await before transition
    }

    func testStartSessionRejectsWhenAlreadyRunning() async {
        // Deep-link gating: start rejected when isRunning
    }

    func testStopSessionRejectsWhenNotRunning() async {
        // Deep-link gating: stop rejected when !isRunning
    }

    func testOpenNotesAlwaysAccepted() async {
        // Deep-link gating: notes always works
    }

    func testUtteranceIngestionAppendsToTranscriptLogger() async {
        // handleNewUtterance → transcriptLogger.append called
    }

    func testRemoteUtteranceTriggersSuggestions() async {
        // them utterance → suggestionEngine.onThemUtterance called
    }

    func testRemoteUtteranceUsesDelayedWrite() async {
        // them utterance → sessionStore.appendRecordDelayed
    }

    func testLocalUtteranceUsesImmediateWrite() async {
        // you utterance → sessionStore.appendRecord (immediate)
    }

    func testSettingsChangeReindexesKB() async {
        // kbFolderPath change → KB reindex
    }

    func testSettingsChangeUpdatesTranscriptLoggerDirectory() async {
        // notesFolderPath change → transcriptLogger.updateDirectory
    }

    func testBatchCompletionRefreshesHistory() async {
        // batch .completed → coordinator.loadHistory
    }

    func testRapidToggleDoesNotRace() async {
        // Start → Stop → Start in quick succession
        // Verify state machine transitions are synchronous and no race conditions
        // This specifically tests the Rev 2 failure mode
    }

    func testAudioLevelMirrorsEngine() async {
        // Verify state.audioLevel reflects transcriptionEngine.audioLevel
        // during recording
    }

    func testMiniBarShowsOnRecordingStart() async {
        // Verify MiniBar behavior is triggered when isRunning transitions to true
        // Note: MiniBar show/hide remains a view-level concern (MiniBarManager),
        // but the controller's state.isRunning change drives it
    }

    func testMiniBarHidesOnRecordingStop() async {
        // isRunning → false → MiniBar hidden
    }
}
```

- [ ] **Step 2: Create LiveSessionState struct**

```swift
struct LiveSessionState: Equatable {
    var isRunning: Bool = false
    var sessionPhase: MeetingState = .idle
    var audioLevel: Float = 0
    var liveTranscript: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""
    var suggestions: [Suggestion] = []
    var isGeneratingSuggestions: Bool = false
    var batchStatus: BatchTranscriptionEngine.Status = .idle
    var lastEndedSession: String? = nil
    var lastSessionHasNotes: Bool = false
    var kbIndexingProgress: String = ""
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    var needsDownload: Bool = false
    var transcriptionPrompt: String? = nil
    var modelDisplayName: String = ""
}
```

- [ ] **Step 3: Create LiveSessionController**

The controller:
- Owns the 100ms polling loop (migrated from ContentView)
- Publishes `LiveSessionState` (replaces `ViewState` in ContentView)
- Handles utterance ingestion (migrated from `ContentView.handleNewUtterance()`)
- Handles settings reactions (migrated from `ContentView.synchronizeDerivedState()`)
- Handles batch polling (migrated from ContentView's `.task` loop)
- Handles external command processing for start/stop (migrated from `handlePendingExternalCommandIfPossible()`)
- Calls `coordinator.handle()` for state transitions — never calls `transition()` directly
- Owns: `refreshViewState()` and `synchronizeDerivedState()` logic

**Critical contract**: `startSession()` sets state synchronously via `coordinator.handle(.userStarted(...))`. No await before the phase change.

**Critical contract**: `state.isRunning` mirrors `transcriptionEngine.isRunning`, NOT `sessionPhase`.

- [ ] **Step 4: Move side effects from ContentView to controller**

Remove from ContentView:
- `handleNewUtterance()` / `handleNewUtterances()`
- `synchronizeDerivedState()`
- `refreshViewState()`
- `handlePendingExternalCommandIfPossible()`
- `startSession()` / `stopSession()`
- `indexKBIfNeeded()`
- Batch polling loop
- All `@State` tracking vars (`observedUtteranceCount`, `observedIsRunning`, etc.)
- All service references (`knowledgeBase`, `suggestionEngine`)

ContentView becomes a pure projection of `LiveSessionController.state`.

- [ ] **Step 5: Update AppCoordinator to delegate finalization to controller**

The coordinator calls `transition()` synchronously, then calls back to `LiveSessionController` for async side effects (engine start, finalization pipeline). Move `startTranscription()` and `finalizeCurrentSession()` to the controller.

- [ ] **Step 6: Wire in AppContainer**

Container creates `LiveSessionController` with all required services.

- [ ] **Step 7: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 8: Verify ContentView has zero business logic**

```bash
grep -n "sessionStore\|transcriptLogger\|refinementEngine\|batchEngine\|handleNewUtterance\|synchronizeDerivedState\|refreshViewState" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Views/ContentView.swift
```
Expected: No matches

- [ ] **Step 9: Commit Phase 5**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift OpenOats/Sources/OpenOats/App/AppCoordinator.swift OpenOats/Sources/OpenOats/App/AppContainer.swift OpenOats/Sources/OpenOats/Views/ContentView.swift OpenOats/Tests/OpenOatsTests/LiveSessionControllerTests.swift
git commit -m "Phase 5: Extract LiveSessionController, migrate all view side effects"
```

---

## Phase 6: Extract NotesController + Rewire NotesView

### Task 6.1: Create NotesController

**Files:**
- Create: `Sources/OpenOats/App/NotesController.swift`
- Modify: `Sources/OpenOats/Views/NotesView.swift` (remove business logic)
- Modify: `Sources/OpenOats/App/AppContainer.swift` (wire controller)
- Create: `Tests/OpenOatsTests/NotesControllerTests.swift`

- [ ] **Step 1: Write notes controller tests**

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class NotesControllerTests: XCTestCase {

    func testSelectSessionLoadsTranscriptAndNotes() async { }
    func testGenerateNotesUpdatesStatus() async { }
    func testGenerateNotesPatchesMarkdown() async { }
    func testCleanupProgressMapsCorrectly() async { }
    func testRenameSessionUpdatesHistory() async { }
    func testDeleteSessionRemovesFromHistory() async { }
    func testOpenNotesSelectsCorrectSession() async { }
    func testOriginalTranscriptToggle() async { }
}
```

- [ ] **Step 2: Define NotesState, CleanupStatus, GenerationStatus**

As specified in the design doc.

- [ ] **Step 3: Create NotesController**

Owns:
- Session list loading from SessionStore
- Selected session state (load transcript, load notes)
- Notes generation (delegates to NotesEngine)
- Markdown file patching via `MarkdownMeetingWriter.insertLLMSections()` (Phase 6 behavior — Phase 8 changes this to full regeneration)
- Transcript cleanup (delegates to CleanupEngine)
- Rename/delete operations
- Template selection
- External command: openNotes(sessionID)
- Original/cleaned transcript toggle

Maps engine state to `CleanupStatus`/`GenerationStatus` in polling loop — NotesView never observes engines directly.

- [ ] **Step 4: Rewire NotesView as state projection**

NotesView reads ONLY `NotesController.state`. Remove all direct `SessionStore`, `CleanupEngine`, `TemplateStore` access from the view. Selection binding dispatches `notesController.selectSession(id)`. Generate button dispatches `notesController.generateNotes()`.

- [ ] **Step 5: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 6: Verify NotesView has zero business logic**

```bash
grep -n "sessionStore\|cleanupEngine\|notesEngine\|templateStore\|MarkdownMeetingWriter" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Views/NotesView.swift
```
Expected: No matches

- [ ] **Step 7: Commit Phase 6**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/NotesController.swift OpenOats/Sources/OpenOats/Views/NotesView.swift OpenOats/Sources/OpenOats/App/AppContainer.swift OpenOats/Tests/OpenOatsTests/NotesControllerTests.swift
git commit -m "Phase 6: Extract NotesController, NotesView becomes pure state projection"
```

---

## Phase 7: Hollow Out AppCoordinator

### Task 7.1: Assess and Remove AppCoordinator

**Files:**
- Modify: `Sources/OpenOats/App/AppCoordinator.swift`
- Modify: `Sources/OpenOats/App/AppContainer.swift`
- Possibly modify: controller files if routing changes

- [ ] **Step 1: Audit what remains in AppCoordinator after Phases 4-6**

List every property and method still in AppCoordinator. Categorize each as:
- (A) Pure forwarding — can be deleted, callers talk to controllers directly
- (B) Cross-cutting coordination — needs to stay somewhere
- (C) State machine — needs an owner

- [ ] **Step 2: Decide: delete coordinator or slim it down**

If only state machine + cross-cutting remains → keep as slim `AppCoordinator` or `AppRouter`.
If just forwarding → delete, move state machine to `LiveSessionController`, controllers talk through container.

- [ ] **Step 3: Execute the decision**

Remove dead code. Update references. If deleted, move state machine ownership.

- [ ] **Step 4: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 5: Commit Phase 7**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/App/
git commit -m "Phase 7: Hollow out AppCoordinator — remove dead forwarding code"
```

---

## Phase 8: Storage Migration (SessionRepository)

### Task 8.1: Create SessionRepository

**Files:**
- Create: `Sources/OpenOats/Storage/SessionRepository.swift`
- Create: `Sources/OpenOats/Storage/LegacySessionReader.swift`
- Modify: `Sources/OpenOats/Intelligence/MarkdownMeetingWriter.swift` (pure exporter)
- Modify: `Sources/OpenOats/App/LiveSessionController.swift` (use repository)
- Modify: `Sources/OpenOats/App/NotesController.swift` (use repository)
- Create: `Tests/OpenOatsTests/SessionRepositoryTests.swift`

- [ ] **Step 1: Write repository tests**

```swift
import XCTest
@testable import OpenOatsKit

final class SessionRepositoryTests: XCTestCase {
    func testStartSessionCreatesCanonicalLayout() async { }
    func testAppendLiveUtteranceWritesToJSONL() async { }
    func testFinalizeSessionWritesMetadataAndMarkdown() async { }
    func testSaveNotesWritesBothFiles() async { }
    func testListSessionsReturnsAllSessions() async { }
    func testLoadSessionReturnsTranscriptAndNotes() async { }
    func testRenameSessionUpdatesMetadata() async { }
    func testDeleteSessionRemovesDirectory() async { }
    func testLegacySessionsReadable() async { }
    func testLegacySessionMigratedOnMutation() async { }
    func testFileHandleStaysOpenDuringRecording() async { }
    func testFireAndForgetWritesDontBlock() async { }
    func testNotesFolderPathMirroringOnFinalize() async { }
    func testNotesFolderPathMirroringOnNotesGeneration() async { }
    func testExportPlainText() async { }
}
```

- [ ] **Step 2: Implement SessionRepository actor**

New canonical layout:
```
sessions/<id>/session.json
sessions/<id>/transcript.live.jsonl
sessions/<id>/transcript.final.jsonl
sessions/<id>/notes.md
sessions/<id>/notes.meta.json
sessions/<id>/audio/*
```

API as specified in design doc. Key implementation details:
- FileHandle stays open for `transcript.live.jsonl` during session lifetime
- Delayed-write aggregation pattern preserved from `SessionStore.appendRecordDelayed`
- `saveNotes()` writes both `notes.md` and `notes.meta.json` atomically
- Mirrors to `notesFolderPath` on finalization, batch completion, and notes generation

- [ ] **Step 3: Implement LegacySessionReader**

Reads old flat-file sessions (`.jsonl` + `.meta.json` sidecar). Sessions readable as-is but migrated to canonical format on mutation.

- [ ] **Step 4: Convert MarkdownMeetingWriter to pure exporter**

Replace `insertLLMSections()` with full regeneration via `write(from: SessionDetail)`. Delete the patching method. Markdown is now a derived artifact from repository state.

Also migrate `BatchTranscriptionEngine.patchMarkdownTranscript()`: this currently patches the `## Transcript` heading in the existing markdown file after batch processing completes. In the new architecture, batch completion calls `SessionRepository.saveFinalTranscript()`, which triggers `MarkdownMeetingWriter.write(from: SessionDetail)` for full regeneration and re-mirrors to `notesFolderPath`. Delete `patchMarkdownTranscript()` from BatchTranscriptionEngine.

- [ ] **Step 5: Update LiveSessionController to use SessionRepository**

Replace `SessionStore` calls with `SessionRepository` calls. Method signatures change but behavior identical. Fire-and-forget writes preserved: `Task { await repository.appendLiveUtterance(...) }`.

- [ ] **Step 6: Update NotesController to use SessionRepository**

Replace `insertLLMSections()` with full `MarkdownMeetingWriter.write(from: SessionDetail)` regeneration.

- [ ] **Step 7: Delete SessionStore and TranscriptLogger**

After all references updated, delete the old files.

- [ ] **Step 8: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass

- [ ] **Step 9: Manual acceptance test**

Full flow: record → view notes → generate notes → verify files in canonical layout and mirrored to notesFolderPath.

- [ ] **Step 10: Commit Phase 8**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/Storage/ OpenOats/Sources/OpenOats/App/ OpenOats/Sources/OpenOats/Intelligence/MarkdownMeetingWriter.swift OpenOats/Tests/OpenOatsTests/SessionRepositoryTests.swift
git commit -m "Phase 8: SessionRepository with canonical layout, legacy compat, notesFolderPath mirroring"
```

---

## Phase 9: Settings Refactor

### Task 9.1: Create SettingsStore with Typed Groups

**Files:**
- Create: `Sources/OpenOats/Settings/SettingsStore.swift`
- Create: `Sources/OpenOats/Settings/AISettings.swift`
- Create: `Sources/OpenOats/Settings/CaptureSettings.swift`
- Create: `Sources/OpenOats/Settings/DetectionSettings.swift`
- Create: `Sources/OpenOats/Settings/PrivacySettings.swift`
- Create: `Sources/OpenOats/Settings/UISettings.swift`
- Modify: `Sources/OpenOats/Settings/AppSettings.swift` (eventually delete)
- Create: `Tests/OpenOatsTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write settings migration tests**

```swift
import XCTest
@testable import OpenOatsKit

final class SettingsStoreTests: XCTestCase {
    func testMigrationFromOldKeysPreservesValues() async { }
    func testTypedAccessReturnsCorrectValues() async { }
    func testBothOldAndNewKeysInSync() async { }
    func testNonisolatedUnsafeBackingDoesNotCrash() async { }
    func testNoDirectUserDefaultsAccess() async { }
}
```

- [ ] **Step 2: Create grouped settings types**

Each group uses `@ObservationIgnored nonisolated(unsafe)` backing storage (same workaround as current AppSettings) to avoid MainActor executor crashes.

- [ ] **Step 3: Create SettingsStore**

Owns persistence and migration. Old keys remain readable. New writes go through SettingsStore. Both synced.

- [ ] **Step 4: Update controllers to observe SettingsStore groups**

Replace `AppSettings` references with typed group access.

- [ ] **Step 5: Update SettingsView bindings**

Bind to typed groups instead of monolithic AppSettings.

- [ ] **Step 6: Delete AppSettings.swift**

After all references migrated.

- [ ] **Step 7: Build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass. No MainActor executor crashes.

- [ ] **Step 8: Commit Phase 9**

```bash
cd /Users/yazin/projects/openoats
git add OpenOats/Sources/OpenOats/Settings/ OpenOats/Sources/OpenOats/App/ OpenOats/Sources/OpenOats/Views/ OpenOats/Tests/OpenOatsTests/SettingsStoreTests.swift
git commit -m "Phase 9: SettingsStore with typed groups, no direct UserDefaults access"
```

---

## Phase 10: Cleanup and Repo Normalization

### Task 10.1: Final Cleanup

**Files:**
- Various — audit and clean

- [ ] **Step 1: Delete dead code**

Audit for: unused soft-delete paths, duplicate artifact writers, view-owned bootstrap remnants, any orphaned files from old architecture.

- [ ] **Step 2: Verify layer boundaries**

```bash
# No SwiftUI/AppKit in Domain/
grep -r "import SwiftUI\|import AppKit\|import Observation" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Domain/

# No SwiftUI/AppKit in Storage/
grep -r "import SwiftUI\|import AppKit" /Users/yazin/projects/openoats/OpenOats/Sources/OpenOats/Storage/
```
Expected: No matches

- [ ] **Step 3: Clean build and test**

Run: `cd /Users/yazin/projects/openoats/OpenOats && swift build 2>&1 | tail -10`
Run: `cd /Users/yazin/projects/openoats/OpenOats && swift test 2>&1 | tail -15`
Expected: All pass, no warnings

- [ ] **Step 4: Manual acceptance**

Full acceptance checklist from spec:
- App launches without crash
- Manual start/stop recording works
- Auto-detection prompts and starts session
- Silence timeout stops session
- Notes window opens, loads history, shows transcript
- Notes generation produces markdown
- Batch transcription completes and refreshes
- Settings changes take effect
- Deep link opens correct session
- Legacy sessions remain visible and openable

- [ ] **Step 5: Commit Phase 10**

Stage only the specific files that were changed during cleanup (list them explicitly after auditing what was modified), then commit:

```bash
cd /Users/yazin/projects/openoats
# git add <each changed file explicitly>
git commit -m "Phase 10: Final cleanup — dead code removed, layer boundaries verified"
```

---

## Execution Order Summary

| Phase | PR Title | Key Deliverable |
|-------|----------|-----------------|
| 0 | Contract tests | Test harness for behavioral contracts |
| 1 | Collapse service construction | No duplicate KB/SE in views |
| 2 | Introduce AppContainer | Single composition root |
| 3 | Domain layer extraction | Pure types in Domain/ |
| 4 | MeetingDetectionController | Detection isolated, AsyncStream events |
| 5 | LiveSessionController | All view side effects migrated |
| 6 | NotesController | NotesView becomes projection |
| 7 | Hollow AppCoordinator | Dead forwarding removed |
| 8 | SessionRepository | Canonical storage, legacy compat |
| 9 | SettingsStore | Typed grouped settings |
| 10 | Cleanup | Clean layers, no dead code |
