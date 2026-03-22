import XCTest
@testable import OpenOatsKit

@MainActor
final class LiveSessionControllerIntegrationTests: XCTestCase {

    func testManualStopFinalizesSessionAndPersistsCanonicalSession() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsLiveSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        let suiteName = "com.openoats.tests.live-session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(notesDirectory.path, forKey: "notesFolderPath")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")
        defaults.set(false, forKey: "enableBatchRefinement")
        defaults.set(false, forKey: "saveAudioRecording")
        defaults.set(false, forKey: "enableTranscriptRefinement")

        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: notesDirectory,
            runMigrations: false
        )
        let settings = AppSettings(storage: storage)
        let transcriptStore = TranscriptStore()
        let repository = SessionRepository(rootDirectory: root)
        let templateStore = TemplateStore(rootDirectory: root)
        let knowledgeBase = KnowledgeBase(settings: settings)
        let suggestionEngine = SuggestionEngine(
            transcriptStore: transcriptStore,
            knowledgeBase: knowledgeBase,
            settings: settings
        )
        let transcriptionEngine = TranscriptionEngine(
            transcriptStore: transcriptStore,
            settings: settings,
            mode: .scripted([
                Utterance(text: "Let me walk through the rollout plan.", speaker: .you),
                Utterance(text: "The pilot scope sounds good to me.", speaker: .them),
            ])
        )
        let controller = LiveSessionController(
            settings: settings,
            repository: repository,
            templateStore: templateStore,
            transcriptStore: transcriptStore,
            knowledgeBase: knowledgeBase,
            suggestionEngine: suggestionEngine,
            transcriptionEngine: transcriptionEngine,
            refinementEngine: TranscriptRefinementEngine(
                settings: settings,
                transcriptStore: transcriptStore
            ),
            audioRecorder: AudioRecorder(outputDirectory: root),
            batchEngine: BatchTranscriptionEngine()
        )

        await controller.activateIfNeeded()
        controller.startManualSession()

        for _ in 0..<20 where !controller.state.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }

        controller.stopSession()

        for _ in 0..<50 where controller.state.lastEndedSession == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let endedSession = controller.state.lastEndedSession else {
            XCTFail("Expected finalized session")
            return
        }

        XCTAssertEqual(endedSession.utteranceCount, 2)

        let summaries = await repository.listSessions()
        let persisted = summaries.first(where: { $0.id == endedSession.id })
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.utteranceCount, 2)
        XCTAssertFalse(persisted?.hasNotes ?? true)

        let session = await repository.loadSession(id: endedSession.id)
        XCTAssertEqual(session.liveTranscript.count, 2)
        XCTAssertEqual(session.liveTranscript.last?.speaker, .them)
    }
}
