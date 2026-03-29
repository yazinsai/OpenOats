import XCTest
@testable import OpenOatsKit

@MainActor
final class NotesContractTests: XCTestCase {

    private func makeTestEnvironment() async -> (SessionRepository, TemplateStore, AppCoordinator, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsNotesTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sessionRepository = SessionRepository(rootDirectory: root)
        let templateStore = TemplateStore(rootDirectory: root)
        let coordinator = AppCoordinator(
            sessionRepository: sessionRepository,
            templateStore: templateStore,
            notesEngine: NotesEngine(mode: .scripted(markdown: "# Test Notes\n\nGenerated.")),
            transcriptStore: TranscriptStore()
        )
        return (sessionRepository, templateStore, coordinator, root)
    }

    func testLoadHistoryReturnsPersistedSessions() async {
        let (sessionRepository, _, coordinator, _) = await makeTestEnvironment()

        await sessionRepository.seedSession(
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
        let (sessionRepository, _, coordinator, _) = await makeTestEnvironment()

        await sessionRepository.seedSession(
            id: "rename_test",
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Original"
        )

        await sessionRepository.renameSession(sessionID: "rename_test", title: "Renamed")
        await coordinator.loadHistory()

        let session = coordinator.sessionHistory.first(where: { $0.id == "rename_test" })
        XCTAssertEqual(session?.title, "Renamed")
    }

    func testSessionDeleteRemovesFromIndex() async {
        let (sessionRepository, _, coordinator, _) = await makeTestEnvironment()

        await sessionRepository.seedSession(
            id: "delete_test",
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "To Delete"
        )

        await sessionRepository.moveToRecentlyDeleted(sessionID: "delete_test")
        await coordinator.loadHistory()

        XCTAssertFalse(coordinator.sessionHistory.contains(where: { $0.id == "delete_test" }))
    }

    func testLoadTranscriptReturnsRecords() async {
        let (sessionRepository, _, _, _) = await makeTestEnvironment()

        let records = [
            SessionRecord(speaker: .you, text: "First", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Second", timestamp: Date()),
        ]
        await sessionRepository.seedSession(
            id: "transcript_test",
            records: records,
            startedAt: Date(),
            endedAt: Date(),
            templateSnapshot: nil,
            title: "Transcript Test"
        )

        let loaded = await sessionRepository.loadTranscript(sessionID: "transcript_test")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "First")
        XCTAssertEqual(loaded[1].text, "Second")
    }

    func testNotesGenerationProducesMarkdownInScriptedMode() async {
        let (_, _, coordinator, root) = await makeTestEnvironment()

        let notesDir = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let suiteName = "com.openoats.tests.notes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(notesDir.path, forKey: "notesFolderPath")
        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: notesDir,
            runMigrations: false
        )
        let settings = AppSettings(storage: storage)

        let records = [
            SessionRecord(speaker: .you, text: "Hello", timestamp: Date()),
            SessionRecord(speaker: .them, text: "World", timestamp: Date()),
        ]
        let template = TemplateStore.builtInTemplates.first!

        let notesEngine = coordinator.notesEngine
        await notesEngine.generate(transcript: records, template: template, settings: settings)

        XCTAssertFalse(notesEngine.generatedMarkdown.isEmpty)
        XCTAssertTrue(notesEngine.generatedMarkdown.contains("Test Notes"))
        XCTAssertFalse(notesEngine.isGenerating)
    }

    func testCleanupEngineExists() async {
        let coordinator = AppCoordinator()
        XCTAssertNotNil(coordinator.batchTextCleaner)
    }
}
