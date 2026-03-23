import XCTest
@testable import OpenOatsKit

@MainActor
final class NotesControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsNotesControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func makeSettings(notesDirectory: URL) -> AppSettings {
        let suiteName = "com.openoats.tests.notescontroller.\(UUID().uuidString)"
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
        return AppSettings(storage: storage)
    }

    private func seedSession(
        coordinator: AppCoordinator,
        sessionID: String = "session_test_001",
        title: String = "Test Meeting",
        utterances: [SessionRecord]? = nil
    ) async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = utterances ?? [
            SessionRecord(speaker: .you, text: "Hello there.", timestamp: startedAt),
            SessionRecord(speaker: .them, text: "Hi, how are you?", timestamp: startedAt.addingTimeInterval(10)),
            SessionRecord(speaker: .you, text: "Great, let's discuss the plan.", timestamp: startedAt.addingTimeInterval(20)),
        ]

        await coordinator.sessionRepository.seedSession(
            id: sessionID,
            records: records,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
            ),
            title: title
        )
        await coordinator.loadHistory()
    }

    private func makeController(root: URL) -> (NotesController, AppCoordinator) {
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "# Test Notes\n\n## Summary\nTest summary.")),
            transcriptStore: TranscriptStore()
        )
        let controller = NotesController(coordinator: coordinator)
        return (controller, coordinator)
    }

    // MARK: - Tests

    func testSelectSessionLoadsTranscriptAndNotes() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_select"

        await seedSession(coordinator: coordinator, sessionID: sessionID)

        controller.selectSession(sessionID)

        // Wait for async load to complete
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
        XCTAssertEqual(controller.state.loadedTranscript.count, 3)
        XCTAssertNil(controller.state.loadedNotes, "No notes should exist before generation")
    }

    func testGenerateNotesUpdatesStatus() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_generate"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        // Scripted engine completes synchronously within Task, give it time
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertNotNil(controller.state.loadedNotes)
        XCTAssertEqual(controller.state.notesGenerationStatus, .completed)
        XCTAssertTrue(controller.state.loadedNotes?.markdown.contains("Test Notes") ?? false)
    }

    func testGenerateNotesSavesNotes() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_patch"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // After generation, notes should be saved to session repository
        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(500))

        let savedNotes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
        XCTAssertNotNil(savedNotes)
        XCTAssertTrue(savedNotes?.markdown.contains("Test Notes") ?? false)
    }

    func testCleanupProgressMapsCorrectly() async {
        let (root, _) = makeTempDirs()
        let (controller, _) = makeController(root: root)

        // When idle with no transcript, should be idle
        XCTAssertEqual(controller.state.cleanupStatus, .idle)
    }

    func testRenameSessionUpdatesHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_rename"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "Original Title")
        await controller.loadHistory()

        let originalSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(originalSession?.title, "Original Title")

        controller.renameSession(sessionID: sessionID, newTitle: "New Title")
        try? await Task.sleep(for: .milliseconds(300))

        let renamedSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(renamedSession?.title, "New Title")
    }

    func testDeleteSessionRemovesFromHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_delete"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await controller.loadHistory()
        XCTAssertTrue(controller.state.sessionHistory.contains { $0.id == sessionID })

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.deleteSession(sessionID: sessionID)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(controller.state.sessionHistory.contains { $0.id == sessionID })
        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
        XCTAssertNil(controller.state.loadedNotes)
    }

    func testOpenNotesSelectsCorrectSession() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_open"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        coordinator.queueSessionSelection(sessionID)

        await controller.onAppear()

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
    }

    func testOriginalTranscriptToggle() async {
        let (root, _) = makeTempDirs()
        let (controller, _) = makeController(root: root)

        XCTAssertFalse(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertTrue(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertFalse(controller.state.showingOriginal)
    }
}
