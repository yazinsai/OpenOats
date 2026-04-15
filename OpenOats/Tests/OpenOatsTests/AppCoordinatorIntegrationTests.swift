import XCTest
@testable import OpenOatsKit

@MainActor
final class AppCoordinatorIntegrationTests: XCTestCase {

    /// Create a coordinator + controller pair wired together for integration tests.
    private func makeTestHarness(
        root: URL,
        notesDirectory: URL,
        scripted: [Utterance]
    ) -> (AppCoordinator, LiveSessionController, AppSettings, SessionRepository) {
        let suiteName = "com.openoats.tests.\(UUID().uuidString)"
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
        let sessionRepository = SessionRepository(rootDirectory: root)
        let coordinator = AppCoordinator(
            sessionRepository: sessionRepository,
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
            defaults: defaults,
            appSupportDirectory: root,
            notesDirectory: notesDirectory
        )
        let controller = LiveSessionController(coordinator: coordinator, container: container)
        coordinator.liveSessionController = controller

        return (coordinator, controller, settings, sessionRepository)
    }

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func makeCalendarEvent(title: String = "Calendar Planning") -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: Date().addingTimeInterval(-300),
            endDate: Date().addingTimeInterval(1_800),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/calendar-planning")
        )
    }

    func testUserStoppedFinalizesSessionAndRefreshesHistory() async {
        let dirs = makeTempDirs()
        let (coordinator, _controller, settings, sessionRepository) = makeTestHarness(
            root: dirs.root,
            notesDirectory: dirs.notes,
            scripted: [
                Utterance(text: "Let me walk through the rollout plan.", speaker: .you),
                Utterance(text: "The pilot scope sounds good to me.", speaker: .them),
            ]
        )

        let metadata = MeetingMetadata(
            detectionContext: DetectionContext(
                signal: .manual,
                detectedAt: Date(),
                meetingApp: nil,
                calendarEvent: nil
            ),
            calendarEvent: nil,
            title: "Coordinator Test",
            startedAt: Date(),
            endedAt: nil
        )

        coordinator.handle(.userStarted(metadata), settings: settings)

        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        coordinator.handle(.userStopped, settings: settings)

        for _ in 0..<50 {
            if coordinator.lastEndedSession != nil, !coordinator.sessionHistory.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let endedSession = coordinator.lastEndedSession else {
            XCTFail("Expected finalized session")
            return
        }

        XCTAssertEqual(endedSession.utteranceCount, 2)
        XCTAssertTrue(coordinator.sessionHistory.contains(where: { $0.id == endedSession.id }))

        let indices = await sessionRepository.listSessions()
        let persisted = indices.first(where: { $0.id == endedSession.id })
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.utteranceCount, 2)
        XCTAssertFalse(persisted?.hasNotes ?? true)

        // Keep controller alive for the duration of the test (weak ref in coordinator)
        withExtendedLifetime(_controller) {}
    }

    func testFinalizationFallsBackToCalendarEventTitle() async {
        let dirs = makeTempDirs()
        let (coordinator, _controller, settings, sessionRepository) = makeTestHarness(
            root: dirs.root,
            notesDirectory: dirs.notes,
            scripted: [
                Utterance(text: "Let's start with the project timeline.", speaker: .you),
            ]
        )

        let event = makeCalendarEvent(title: "Calendar Planning")
        coordinator.handle(.userStarted(.manual(calendarEvent: event)), settings: settings)

        for _ in 0..<20 {
            if coordinator.transcriptionEngine?.isRunning == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        coordinator.handle(.userStopped, settings: settings)

        for _ in 0..<50 {
            if case .idle = coordinator.state, coordinator.lastEndedSession != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let endedSession = coordinator.lastEndedSession else {
            XCTFail("Expected finalized session")
            return
        }

        XCTAssertEqual(endedSession.title, "Calendar Planning")

        let indices = await sessionRepository.listSessions()
        let persisted = indices.first(where: { $0.id == endedSession.id })
        XCTAssertEqual(persisted?.title, "Calendar Planning")

        withExtendedLifetime(_controller) {}
    }

    func testFinalizationWritesSidecarWithCorrectMetadata() async {
        let dirs = makeTempDirs()
        let (coordinator, _controller, settings, sessionRepository) = makeTestHarness(
            root: dirs.root,
            notesDirectory: dirs.notes,
            scripted: [
                Utterance(text: "Hello from you.", speaker: .you),
                Utterance(text: "Hello from them.", speaker: .them),
            ]
        )

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

        // Verify session metadata was written
        let indices = await sessionRepository.listSessions()
        XCTAssertFalse(indices.isEmpty)
        let session = indices.first!
        XCTAssertFalse(session.hasNotes)
        XCTAssertEqual(session.utteranceCount, 2)

        withExtendedLifetime(_controller) {}
    }

    func testFinalizationTimeoutForcesIdleState() async {
        let coordinator = AppCoordinator()
        let metadata = MeetingMetadata.manual()

        coordinator.handle(.userStarted(metadata))
        XCTAssertEqual(coordinator.isRecording, true)

        coordinator.handle(.userStopped)
        coordinator.handle(.finalizationTimeout)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDiscardReturnsToIdleWithoutFinalization() async {
        let coordinator = AppCoordinator()
        let metadata = MeetingMetadata.manual()

        coordinator.handle(.userStarted(metadata))
        XCTAssertEqual(coordinator.isRecording, true)

        coordinator.handle(.userDiscarded)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.lastEndedSession)
    }
}
