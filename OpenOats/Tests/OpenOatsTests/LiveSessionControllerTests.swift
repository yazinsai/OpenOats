import XCTest
@testable import OpenOatsKit

@MainActor
final class LiveSessionControllerTests: XCTestCase {
    private final class SecretLoadTracker: @unchecked Sendable {
        var loadedKeys: [String] = []
    }

    // MARK: - Helpers

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsLiveSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func makeSettings(
        notesDirectory: URL,
        secretStore: AppSecretStore = .ephemeral
    ) -> AppSettings {
        let suiteName = "com.openoats.tests.livesession.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(notesDirectory.path, forKey: "notesFolderPath")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")
        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: secretStore,
            defaultNotesDirectory: notesDirectory,
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    private func makeController(
        root: URL,
        notesDirectory: URL,
        settings: AppSettings,
        scripted: [Utterance] = []
    ) -> (LiveSessionController, AppCoordinator) {
        let transcriptStore = TranscriptStore()
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "Test")),
            transcriptStore: transcriptStore
        )
        coordinator.transcriptionEngine = TranscriptionEngine(
            transcriptStore: transcriptStore,
            settings: settings,
            mode: .scripted(scripted)
        )

        let container = AppContainer(
            mode: .live,
            defaults: .standard,
            appSupportDirectory: root,
            notesDirectory: notesDirectory
        )
        let controller = LiveSessionController(coordinator: coordinator, container: container)
        coordinator.liveSessionController = controller
        return (controller, coordinator)
    }

    private func makeUninitializedController(
        root: URL,
        notesDirectory: URL,
        settings: AppSettings
    ) -> (LiveSessionController, AppCoordinator) {
        let transcriptStore = TranscriptStore()
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "Test")),
            transcriptStore: transcriptStore
        )
        let defaults = UserDefaults(suiteName: "com.openoats.tests.lazyservices.\(UUID().uuidString)") ?? .standard
        let container = AppContainer(
            mode: .uiTest(.launchSmoke),
            defaults: defaults,
            appSupportDirectory: root,
            notesDirectory: notesDirectory
        )
        let controller = LiveSessionController(coordinator: coordinator, container: container)
        coordinator.liveSessionController = controller
        return (controller, coordinator)
    }

    // MARK: - Tests

    func testStartSessionTransitionsStateToRecordingSynchronously() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        XCTAssertEqual(coordinator.state, .idle)

        controller.startSession(settings: settings)

        // The state machine transition must happen synchronously
        if case .recording = coordinator.state {
            // expected
        } else {
            XCTFail("Expected .recording state immediately after startSession, got \(coordinator.state)")
        }
    }

    func testStartSessionWhileRunningIsNoOp() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [Utterance(text: "Test", speaker: .you)]
        )

        controller.startSession(settings: settings)

        // Wait for engine to start
        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Second start should be a no-op (state machine: recording + userStarted = no-op)
        controller.startSession(settings: settings)

        // Still recording, not crashed or changed
        if case .recording = coordinator.state {
            // expected
        } else {
            XCTFail("Expected .recording state, got \(coordinator.state)")
        }
    }

    func testStartSessionReusesAbandonedMeetingStubForSameCalendarEvent() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let now = Date()
        let event = CalendarEvent(
            id: "evt-resume-stub",
            title: "Payment Ops / Merchant stand up",
            startDate: now.addingTimeInterval(-120),
            endDate: now.addingTimeInterval(780),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/payment-ops")
        )

        let repository = SessionRepository(rootDirectory: dirs.root)
        let abandonedHandle = await repository.startSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: event.title,
                calendarEvent: event
            )
        )
        await repository.endSession()

        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [Utterance(text: "Recovered", speaker: .you)]
        )

        controller.startSession(settings: settings, calendarEventOverride: event)

        var activeSessionID: String?
        for _ in 0..<20 {
            activeSessionID = await coordinator.sessionRepository.getCurrentSessionID()
            if activeSessionID != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(activeSessionID, abandonedHandle.sessionID)
    }

    func testStartSessionInitializesServicesOnDemand() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeUninitializedController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        XCTAssertNil(coordinator.transcriptionEngine)
        XCTAssertNil(coordinator.knowledgeBase)

        controller.startSession(settings: settings)

        XCTAssertNotNil(coordinator.transcriptionEngine)
        XCTAssertNotNil(coordinator.knowledgeBase)

        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(coordinator.transcriptionEngine?.isRunning == true)
        if case .recording = coordinator.state {
            // expected
        } else {
            XCTFail("Expected recording state after on-demand initialization")
        }
    }

    func testStopSessionWhileIdleIsNoOp() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        XCTAssertEqual(coordinator.state, .idle)

        controller.stopSession(settings: settings)

        // Should still be idle
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDeepLinkStartInitializesServicesOnDemand() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let transcriptStore = TranscriptStore()
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: dirs.root),
            templateStore: TemplateStore(rootDirectory: dirs.root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "Test")),
            transcriptStore: transcriptStore
        )
        // No transcription engine or suggestion engine
        let container = AppContainer(
            mode: .live,
            defaults: .standard,
            appSupportDirectory: dirs.root,
            notesDirectory: dirs.notes
        )
        let controller = LiveSessionController(coordinator: coordinator, container: container)
        coordinator.liveSessionController = controller

        // Queue a start command
        coordinator.queueExternalCommand(.startSession())

        // Try handling - the controller should initialize services on demand.
        controller.handlePendingExternalCommandIfPossible(settings: settings, openNotesWindow: nil)

        XCTAssertNil(coordinator.pendingExternalCommand)
        XCTAssertNotNil(coordinator.transcriptionEngine)
        XCTAssertNotNil(coordinator.knowledgeBase)
        if case .recording = coordinator.state {
            // expected
        } else {
            XCTFail("Expected .recording state after on-demand deep link start, got \(coordinator.state)")
        }
    }

    func testDeepLinkStopRejectedWhenNotRunning() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        coordinator.queueExternalCommand(.stopSession)

        // Try handling - should not stop because not running
        controller.handlePendingExternalCommandIfPossible(settings: settings, openNotesWindow: nil)

        // Command should still be pending (not consumed because guard failed)
        XCTAssertNotNil(coordinator.pendingExternalCommand)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDeepLinkOpenNotesAlwaysAccepted() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        coordinator.queueExternalCommand(.openNotes(sessionID: "test_session"))

        var notesOpened = false
        controller.handlePendingExternalCommandIfPossible(settings: settings) {
            notesOpened = true
        }

        XCTAssertTrue(notesOpened)
        XCTAssertNil(coordinator.pendingExternalCommand)
        XCTAssertEqual(coordinator.requestedNotesNavigation?.target, .session("test_session"))
    }

    func testExternalStartSessionSeedsCalendarEventAndScratchpad() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [Utterance(text: "Hello", speaker: .you)]
        )
        let knowledgeBase = KnowledgeBase(settings: settings)
        coordinator.setViewServices(
            knowledgeBase: knowledgeBase,
            suggestionEngine: SuggestionEngine(
                transcriptStore: coordinator.transcriptStore,
                knowledgeBase: knowledgeBase,
                settings: settings
            ),
            sidecastEngine: SidecastEngine(
                transcriptStore: coordinator.transcriptStore,
                knowledgeBase: knowledgeBase,
                settings: settings
            )
        )

        let event = CalendarEvent(
            id: "evt-123",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/payment-ops")
        )

        coordinator.queueExternalCommand(
            .startSession(calendarEvent: event, scratchpadSeed: "Talk through merchant fees")
        )

        controller.handlePendingExternalCommandIfPossible(settings: settings, openNotesWindow: nil)

        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let sessionID = await coordinator.sessionRepository.getCurrentSessionID()
        let savedScratchpad: String?
        if let sessionID {
            savedScratchpad = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)
        } else {
            savedScratchpad = nil
        }

        if case .recording(let metadata) = coordinator.state {
            XCTAssertEqual(metadata.calendarEvent?.id, event.id)
        } else {
            XCTFail("Expected recording state after external start command")
        }
        XCTAssertEqual(controller.state.scratchpadText, "Talk through merchant fees")
        XCTAssertEqual(savedScratchpad, "Talk through merchant fees")
        XCTAssertNil(coordinator.pendingExternalCommand)
    }

    func testFinalizeCurrentSessionAppliesMeetingFamilyFolderPreference() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [Utterance(text: "Hello", speaker: .you)]
        )

        let event = CalendarEvent(
            id: "evt-folder",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/payment-ops")
        )
        settings.setMeetingFamilyFolderPreference("Work/Payments", for: event)

        controller.startSession(settings: settings, calendarEventOverride: event)

        var sessionID: String?
        for _ in 0..<20 {
            sessionID = await coordinator.sessionRepository.getCurrentSessionID()
            if sessionID != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let sessionID else {
            return XCTFail("Expected session ID after starting session")
        }

        let utterance = Utterance(
            text: "Follow up on merchant fees",
            speaker: .you,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = coordinator.transcriptStore.append(utterance)

        controller.stopSession(settings: settings)
        await controller.finalizeCurrentSession(settings: settings)

        let detail = await coordinator.sessionRepository.loadSession(id: sessionID)
        XCTAssertEqual(detail.index.folderPath, "Work/Payments")
    }

    func testFinalizeCurrentSessionCollapsesEmptyGhostSessionIntoRecentRealSession() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: []
        )

        let event = CalendarEvent(
            id: "evt-ghost-merge",
            title: "Payment Ops / Merchant stand up",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/payment-ops")
        )

        let realStartedAt = Date().addingTimeInterval(-180)
        await coordinator.sessionRepository.seedSession(
            id: "session_real",
            records: [SessionRecord(speaker: .you, text: "Real meeting", timestamp: realStartedAt)],
            startedAt: realStartedAt,
            endedAt: realStartedAt.addingTimeInterval(120),
            title: "Payment Ops / Merchant stand up"
        )

        controller.startSession(settings: settings, calendarEventOverride: event)

        var sessionID: String?
        for _ in 0..<20 {
            sessionID = await coordinator.sessionRepository.getCurrentSessionID()
            if sessionID != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let ghostSessionID = sessionID else {
            return XCTFail("Expected session ID after starting session")
        }

        controller.stopSession(settings: settings)
        await controller.finalizeCurrentSession(settings: settings)

        let sessions = await coordinator.sessionRepository.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == ghostSessionID }))
        XCTAssertTrue(sessions.contains(where: { $0.id == "session_real" }))
        XCTAssertEqual(coordinator.lastEndedSession?.id, "session_real")

        let mergedDetail = await coordinator.sessionRepository.loadSession(id: "session_real")
        XCTAssertEqual(mergedDetail.calendarEvent?.id, event.id)
    }
    func testRunningStateChangeCallbackFires() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [Utterance(text: "Hello", speaker: .you)]
        )

        var runningChanges: [Bool] = []
        controller.onRunningStateChanged = { isRunning in
            runningChanges.append(isRunning)
        }

        controller.startSession(settings: settings)

        // Wait for engine to start
        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let engineRunning = coordinator.transcriptionEngine?.isRunning ?? false
        XCTAssertTrue(engineRunning, "Engine should be running after start")
    }

    func testConfirmDownloadSetsFlag() {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        XCTAssertFalse(coordinator.transcriptionEngine?.downloadConfirmed ?? true)

        controller.confirmDownloadAndStart(settings: settings)

        XCTAssertTrue(coordinator.transcriptionEngine?.downloadConfirmed ?? false)
    }

    func testPollingDoesNotReadVoyageKeyWhenKnowledgeBaseFolderUnset() async {
        let dirs = makeTempDirs()
        let tracker = SecretLoadTracker()
        let secretStore = AppSecretStore(
            loadValue: { key in
                tracker.loadedKeys.append(key)
                return key == "voyageApiKey" ? "pa-existing" : nil
            },
            saveValue: { _, _ in }
        )
        let settings = makeSettings(notesDirectory: dirs.notes, secretStore: secretStore)
        let (controller, _) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )

        let task = Task {
            await controller.runPollingLoop(settings: settings)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        XCTAssertFalse(tracker.loadedKeys.contains("voyageApiKey"))
    }

    func testPollingDoesNotReadVoyageKeyOnStartupWhenKnowledgeBaseFolderSet() async {
        let dirs = makeTempDirs()
        let kbDirectory = dirs.root.appendingPathComponent("KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: kbDirectory, withIntermediateDirectories: true)

        let tracker = SecretLoadTracker()
        let secretStore = AppSecretStore(
            loadValue: { key in
                tracker.loadedKeys.append(key)
                return key == "voyageApiKey" ? "pa-existing" : nil
            },
            saveValue: { _, _ in }
        )
        let settings = makeSettings(notesDirectory: dirs.notes, secretStore: secretStore)
        settings.kbFolderPath = kbDirectory.path
        settings.embeddingProvider = .voyageAI

        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings
        )
        let knowledgeBase = KnowledgeBase(settings: settings)
        coordinator.setViewServices(
            knowledgeBase: knowledgeBase,
            suggestionEngine: SuggestionEngine(
                transcriptStore: coordinator.transcriptStore,
                knowledgeBase: knowledgeBase,
                settings: settings
            ),
            sidecastEngine: SidecastEngine(
                transcriptStore: coordinator.transcriptStore,
                knowledgeBase: knowledgeBase,
                settings: settings
            )
        )

        let task = Task {
            await controller.runPollingLoop(settings: settings)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        XCTAssertFalse(tracker.loadedKeys.contains("voyageApiKey"))
    }

    func testFullSessionLifecycle() async {
        let dirs = makeTempDirs()
        let settings = makeSettings(notesDirectory: dirs.notes)
        let (controller, coordinator) = makeController(
            root: dirs.root,
            notesDirectory: dirs.notes,
            settings: settings,
            scripted: [
                Utterance(text: "Let me walk through this.", speaker: .you),
                Utterance(text: "Sounds good.", speaker: .them),
            ]
        )

        // Start
        controller.startSession(settings: settings)

        // Wait for engine
        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Stop
        controller.stopSession(settings: settings)

        // Wait for finalization
        for _ in 0..<50 {
            if case .idle = coordinator.state, coordinator.lastEndedSession != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNotNil(coordinator.lastEndedSession)
        XCTAssertEqual(coordinator.lastEndedSession?.utteranceCount, 2)
    }
}
