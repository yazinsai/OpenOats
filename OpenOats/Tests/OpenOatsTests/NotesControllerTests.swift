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
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_cleanup_mapping"

        // When idle with no transcript, should be idle initially
        XCTAssertEqual(controller.state.cleanupStatus, .idle)
        
        let cleanedRecord = SessionRecord(
            speaker: .you,
            text: "Raw text.",
            timestamp: Date(),
            cleanedText: "Cleaned text."
        )
        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [cleanedRecord])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Ensure cleanupStatus maps to completed since transcript has cleaned elements
        XCTAssertEqual(controller.state.cleanupStatus, .completed)
    }

    func testCleanupProgressIdleForUncleanedTranscript() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_cleanup_idle"
        
        let uncleanedRecord = SessionRecord(
            speaker: .you,
            text: "Raw text only.",
            timestamp: Date(),
            cleanedText: nil
        )
        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [uncleanedRecord])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Ensure cleanupStatus is idle since transcript has no cleaned elements
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

    func testGenerateNotesPrependsTitleHeading() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_heading"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "Q4 Planning")
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(500))

        let markdown = controller.state.loadedNotes?.markdown ?? ""
        XCTAssertTrue(markdown.hasPrefix("# Meeting Notes: Q4 Planning\n\n"))
    }

    func testGenerateNotesHeadingFallsBackToDate() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_heading_fallback"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "")
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(500))

        let markdown = controller.state.loadedNotes?.markdown ?? ""
        XCTAssertTrue(markdown.hasPrefix("# Meeting Notes: "), "Should have heading with date fallback")
        XCTAssertFalse(markdown.hasPrefix("# Meeting Notes: \n"), "Should not have empty title")
    }

    func testNotesHeadingStaticHelper() {
        let withTitle = NotesController.notesHeading(title: "Standup", date: Date())
        XCTAssertEqual(withTitle, "# Meeting Notes: Standup\n\n")

        let withEmpty = NotesController.notesHeading(title: "", date: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(withEmpty.hasPrefix("# Meeting Notes: "))
        XCTAssertFalse(withEmpty.contains("# Meeting Notes: \n"))

        let withNil = NotesController.notesHeading(title: nil, date: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(withNil.hasPrefix("# Meeting Notes: "))
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

    func testGenerateNotesUpdatesGeneratingFlags() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_flags"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertFalse(controller.isGenerating(sessionID: sessionID))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        
        // Synchronous start
        XCTAssertTrue(controller.isAnyGenerationInProgress)
        XCTAssertTrue(controller.isGenerating(sessionID: sessionID))
        XCTAssertEqual(controller.generatingSessionName, "Test Meeting")

        // Wait for finish
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertFalse(controller.isGenerating(sessionID: sessionID))
    }

    func testGenerateNotesUpdatesFreshlyGeneratedWhenSwitchedAway() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_fresh_switch"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Start generation
        controller.generateNotes(sessionID: sessionID, settings: settings)

        // Switch to a different session (or nil) immediately
        controller.selectSession(nil)

        // Wait for generation to finish in the background
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertTrue(controller.state.freshlyGeneratedSessionIDs.contains(sessionID))
        XCTAssertNil(controller.state.loadedNotes, "Should not update loadedNotes for the current unselected view")

        // Switch back to it
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(controller.state.freshlyGeneratedSessionIDs.contains(sessionID), "Should clear the fresh badge when selected")
        XCTAssertNotNil(controller.state.loadedNotes, "Should load the generated notes")
    }

    func testAllTagsHidesGranolaImportMetadataTags() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "session_local", title: "Local")
        await coordinator.sessionRepository.updateSessionTags(
            sessionID: "session_local",
            tags: ["follow-up"]
        )

        await seedSession(coordinator: coordinator, sessionID: "session_granola", title: "Imported")
        await coordinator.sessionRepository.updateSessionSource(
            sessionID: "session_granola",
            source: "granola",
            tags: ["granola:not_123"]
        )
        await coordinator.sessionRepository.updateSessionTags(
            sessionID: "session_granola",
            tags: ["customer"]
        )

        await controller.loadHistory()

        let tags = await controller.allTags()

        XCTAssertEqual(tags, ["customer", "follow-up"])
        XCTAssertFalse(tags.contains(where: { $0.hasPrefix("granola:") }))
    }

    func testSessionSourceGroupsKeepGranolaSeparateFromOpenOats() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "session_local", title: "Local")

        await seedSession(coordinator: coordinator, sessionID: "session_granola", title: "Imported")
        await coordinator.sessionRepository.updateSessionSource(
            sessionID: "session_granola",
            source: "granola",
            tags: ["granola:not_456"]
        )

        await controller.loadHistory()

        let groups = controller.sessionSourceGroups

        XCTAssertEqual(groups.map(\.title), ["OpenOats", "Granola"])
        XCTAssertEqual(groups.first?.sessions.map(\.id), ["session_local"])
        XCTAssertEqual(groups.last?.sessions.map(\.id), ["session_granola"])
        XCTAssertTrue(controller.showsSourceSections)
    }
}
