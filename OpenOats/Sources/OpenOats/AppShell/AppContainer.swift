import Foundation

struct AppContainerBootstrap {
    let container: AppContainer
    let updaterController: AppUpdaterController
}

@MainActor
final class AppContainer {
    static let notesSmokeSessionID = "session_ui_test_notes"

    let mode: AppRuntimeMode
    let defaults: UserDefaults

    let settings: SettingsStore
    let templateStore: TemplateStore
    let repository: SessionRepository
    let navigationState: AppNavigationState
    let liveSessionController: LiveSessionController
    let meetingDetectionController: MeetingDetectionController
    let notesController: NotesController

    private var didSeedInitialData = false
    private var didActivate = false

    init(
        mode: AppRuntimeMode,
        defaults: UserDefaults,
        settings: SettingsStore,
        templateStore: TemplateStore,
        repository: SessionRepository,
        navigationState: AppNavigationState,
        liveSessionController: LiveSessionController,
        meetingDetectionController: MeetingDetectionController,
        notesController: NotesController
    ) {
        self.mode = mode
        self.defaults = defaults
        self.settings = settings
        self.templateStore = templateStore
        self.repository = repository
        self.navigationState = navigationState
        self.liveSessionController = liveSessionController
        self.meetingDetectionController = meetingDetectionController
        self.notesController = notesController
    }

    static func bootstrap() -> AppContainerBootstrap {
        let environment = ProcessInfo.processInfo.environment
        let mode = runtimeMode(from: environment)

        switch mode {
        case .live:
            let defaults = UserDefaults.standard
            let appSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("OpenOats", isDirectory: true)
            let settings = AppSettings()
            let updaterController = AppUpdaterController()
            let container = makeContainer(
                mode: mode,
                defaults: defaults,
                appSupportDirectory: appSupportDirectory,
                settings: settings,
                notesEngine: NotesEngine()
            )
            return AppContainerBootstrap(container: container, updaterController: updaterController)

        case .uiTest(let scenario):
            let runID = environment["OPENOATS_UI_TEST_RUN_ID"] ?? UUID().uuidString
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("OpenOatsUITests", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
            let appSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
            let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

            let suiteName = "com.openoats.uitests.\(runID)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")
            defaults.set(false, forKey: "meetingAutoDetectEnabled")
            defaults.set(false, forKey: "hasShownAutoDetectExplanation")
            defaults.set(false, forKey: "hideFromScreenShare")
            defaults.set(true, forKey: "showLiveTranscript")
            defaults.set(false, forKey: "saveAudioRecording")
            defaults.set(false, forKey: "enableTranscriptRefinement")
            defaults.set(notesDirectory.path, forKey: "notesFolderPath")
            defaults.set("", forKey: "kbFolderPath")

            let storage = AppSettingsStorage(
                defaults: defaults,
                secretStore: .ephemeral,
                defaultNotesDirectory: notesDirectory,
                runMigrations: false
            )
            let settings = AppSettings(storage: storage)
            let notesEngine = NotesEngine(mode: .scripted(markdown: Self.scriptedNotesMarkdown))
            let updaterController = AppUpdaterController(startUpdater: false)
            let container = makeContainer(
                mode: .uiTest(scenario),
                defaults: defaults,
                appSupportDirectory: appSupportDirectory,
                settings: settings,
                notesEngine: notesEngine
            )
            return AppContainerBootstrap(container: container, updaterController: updaterController)
        }
    }

    func activateIfNeeded() async {
        guard !didActivate else { return }
        didActivate = true

        await seedIfNeeded()
        await liveSessionController.activateIfNeeded()
        await meetingDetectionController.activateIfNeeded()
        await notesController.activateIfNeeded()
    }

    // MARK: - Private

    private static func makeContainer(
        mode: AppRuntimeMode,
        defaults: UserDefaults,
        appSupportDirectory: URL,
        settings: SettingsStore,
        notesEngine: NotesEngine
    ) -> AppContainer {
        let repository = SessionRepository(rootDirectory: appSupportDirectory)
        let templateStore = TemplateStore(rootDirectory: appSupportDirectory)
        let navigationState = AppNavigationState()
        let transcriptStore = TranscriptStore()
        let knowledgeBase = KnowledgeBase(settings: settings)
        let suggestionEngine = SuggestionEngine(
            transcriptStore: transcriptStore,
            knowledgeBase: knowledgeBase,
            settings: settings
        )
        let transcriptionEngine = switch mode {
        case .live:
            TranscriptionEngine(transcriptStore: transcriptStore, settings: settings)
        case .uiTest:
            TranscriptionEngine(
                transcriptStore: transcriptStore,
                settings: settings,
                mode: .scripted(Self.scriptedUtterances)
            )
        }
        let refinementEngine = TranscriptRefinementEngine(
            settings: settings,
            transcriptStore: transcriptStore
        )
        let audioRecorder = AudioRecorder(
            outputDirectory: appSupportDirectory.appendingPathComponent("sessions", isDirectory: true)
        )
        let batchEngine = BatchTranscriptionEngine()
        let cleanupEngine = TranscriptCleanupEngine()

        let liveSessionController = LiveSessionController(
            settings: settings,
            repository: repository,
            templateStore: templateStore,
            transcriptStore: transcriptStore,
            knowledgeBase: knowledgeBase,
            suggestionEngine: suggestionEngine,
            transcriptionEngine: transcriptionEngine,
            refinementEngine: refinementEngine,
            audioRecorder: audioRecorder,
            batchEngine: batchEngine
        )
        let meetingDetectionController = MeetingDetectionController(
            settings: settings,
            liveSessionController: liveSessionController
        )
        let notesController = NotesController(
            settings: settings,
            repository: repository,
            templateStore: templateStore,
            notesEngine: notesEngine,
            cleanupEngine: cleanupEngine,
            navigationState: navigationState
        )

        liveSessionController.onUtteranceFinalized = { [weak meetingDetectionController] _ in
            meetingDetectionController?.noteUtterance()
        }
        liveSessionController.onRepositoryChanged = { [weak notesController] in
            await notesController?.refreshSessions()
        }
        notesController.onRepositoryChanged = { [weak liveSessionController] in
            await liveSessionController?.refreshRepositoryState()
        }

        return AppContainer(
            mode: mode,
            defaults: defaults,
            settings: settings,
            templateStore: templateStore,
            repository: repository,
            navigationState: navigationState,
            liveSessionController: liveSessionController,
            meetingDetectionController: meetingDetectionController,
            notesController: notesController
        )
    }

    private func seedIfNeeded() async {
        guard !didSeedInitialData else { return }
        didSeedInitialData = true

        guard case .uiTest(let scenario) = mode, scenario == .notesSmoke else {
            return
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = [
            SessionRecord(
                speaker: .you,
                text: "Thanks for taking the time today. I wanted to walk through the pilot scope.",
                timestamp: startedAt
            ),
            SessionRecord(
                speaker: .them,
                text: "That makes sense. The main thing we care about is faster onboarding for new reps.",
                timestamp: startedAt.addingTimeInterval(30)
            ),
            SessionRecord(
                speaker: .you,
                text: "Great. We can start with one team, define baseline metrics, and report back in two weeks.",
                timestamp: startedAt.addingTimeInterval(60)
            ),
        ]

        await repository.seedSession(
            id: Self.notesSmokeSessionID,
            records: transcript,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            templateSnapshot: templateStore.snapshot(
                of: templateStore.template(for: TemplateStore.genericID)
                    ?? TemplateStore.builtInTemplates.first!
            ),
            title: "UI Test Discovery Call"
        )
    }

    private static func runtimeMode(from environment: [String: String]) -> AppRuntimeMode {
        guard environment["OPENOATS_UI_TEST"] == "1" else {
            return .live
        }

        let scenario = UITestScenario(rawValue: environment["OPENOATS_UI_SCENARIO"] ?? "")
            ?? .launchSmoke
        return .uiTest(scenario)
    }

    private static let scriptedUtterances: [Utterance] = [
        Utterance(
            text: "Thanks for joining. I want to show how the rollout plan works for new customers.",
            speaker: .you,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        ),
        Utterance(
            text: "Sounds good. I mostly care about getting the first team live quickly and measuring adoption.",
            speaker: .them,
            timestamp: Date(timeIntervalSince1970: 1_700_000_130)
        ),
    ]

    private static let scriptedNotesMarkdown = """
    # UI Test Notes

    ## Summary
    The pilot focuses on getting one team live quickly and measuring onboarding impact.

    ## Action Items
    - Define baseline metrics for the first pilot team.
    - Report initial results after two weeks.
    """
}
