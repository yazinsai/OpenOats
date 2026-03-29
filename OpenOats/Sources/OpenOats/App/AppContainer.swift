import Foundation
import Observation

@MainActor
@Observable
final class AppContainer {
    static let notesSmokeSessionID = "session_ui_test_notes"

    let mode: AppRuntimeMode
    let defaults: UserDefaults
    let appSupportDirectory: URL
    let notesDirectory: URL

    /// Detection controller for the meeting auto-detect lifecycle.
    /// Created when detection is enabled; nil otherwise.
    private(set) var detectionController: MeetingDetectionController?

    /// Shared notification service, accessible for batch completion notifications
    /// even when detection is not enabled.
    private(set) var notificationService: NotificationService?

    private var didSeedInitialData = false
    private var didInitializeServices = false

    init(
        mode: AppRuntimeMode,
        defaults: UserDefaults,
        appSupportDirectory: URL,
        notesDirectory: URL
    ) {
        self.mode = mode
        self.defaults = defaults
        self.appSupportDirectory = appSupportDirectory
        self.notesDirectory = notesDirectory
    }

    static func bootstrap() -> AppLaunchContext {
        let environment = ProcessInfo.processInfo.environment
        let mode = runtimeMode(from: environment)

        switch mode {
        case .live:
            let container = AppContainer(
                mode: .live,
                defaults: .standard,
                appSupportDirectory: FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!.appendingPathComponent("OpenOats", isDirectory: true),
                notesDirectory: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/OpenOats", isDirectory: true)
            )
            let settings = AppSettings()
            let coordinator = AppCoordinator()
            let updaterController = AppUpdaterController()
            return AppLaunchContext(
                isFirstLaunch: false,
                uiTestScenario: nil,
                runtimeMode: .live,
                container: container,
                settings: settings,
                coordinator: coordinator,
                updaterController: updaterController
            )

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
            let notesEngine = NotesEngine(mode: .scripted(markdown: scriptedNotesMarkdown))
            let coordinator = AppCoordinator(
                sessionRepository: SessionRepository(rootDirectory: appSupportDirectory),
                templateStore: TemplateStore(rootDirectory: appSupportDirectory),
                notesEngine: notesEngine,
                transcriptStore: TranscriptStore()
            )
            let container = AppContainer(
                mode: .uiTest(scenario),
                defaults: defaults,
                appSupportDirectory: appSupportDirectory,
                notesDirectory: notesDirectory
            )
            let updaterController = AppUpdaterController(startUpdater: false)
            return AppLaunchContext(
                isFirstLaunch: false,
                uiTestScenario: scenario,
                runtimeMode: .uiTest(scenario),
                container: container,
                settings: settings,
                coordinator: coordinator,
                updaterController: updaterController
            )
        }
    }

    func makeServices(settings: AppSettings, coordinator: AppCoordinator) -> AppServices {
        let knowledgeBase = KnowledgeBase(settings: settings)
        let suggestionEngine = SuggestionEngine(
            transcriptStore: coordinator.transcriptStore,
            knowledgeBase: knowledgeBase,
            settings: settings
        )
        let sidecastEngine = SidecastEngine(
            transcriptStore: coordinator.transcriptStore,
            knowledgeBase: knowledgeBase,
            settings: settings
        )

        let transcriptionEngine: TranscriptionEngine
        switch mode {
        case .live:
            transcriptionEngine = TranscriptionEngine(
                transcriptStore: coordinator.transcriptStore,
                settings: settings
            )
        case .uiTest:
            transcriptionEngine = TranscriptionEngine(
                transcriptStore: coordinator.transcriptStore,
                settings: settings,
                mode: .scripted(Self.scriptedUtterances)
            )
        }

        return AppServices(
            knowledgeBase: knowledgeBase,
            suggestionEngine: suggestionEngine,
            sidecastEngine: sidecastEngine,
            transcriptionEngine: transcriptionEngine,
            refinementEngine: TranscriptRefinementEngine(
                settings: settings,
                transcriptStore: coordinator.transcriptStore
            ),
            audioRecorder: AudioRecorder(outputDirectory: notesDirectory),
            batchEngine: BatchTranscriptionEngine()
        )
    }

    func ensureServicesInitialized(settings: AppSettings, coordinator: AppCoordinator) {
        guard !didInitializeServices else { return }
        didInitializeServices = true

        let services = makeServices(settings: settings, coordinator: coordinator)
        coordinator.transcriptionEngine = services.transcriptionEngine
        coordinator.refinementEngine = services.refinementEngine
        coordinator.audioRecorder = services.audioRecorder
        coordinator.batchEngine = services.batchEngine
        coordinator.setViewServices(
            knowledgeBase: services.knowledgeBase,
            suggestionEngine: services.suggestionEngine,
            sidecastEngine: services.sidecastEngine
        )
    }

    /// Create and start the detection controller, wire the coordinator event loop.
    func enableDetection(settings: AppSettings, coordinator: AppCoordinator) {
        guard detectionController == nil else { return }
        let controller = MeetingDetectionController()
        controller.isSessionActive = { [weak coordinator] in
            guard let coordinator else { return false }
            return coordinator.isRecording
        }
        detectionController = controller
        controller.setup(settings: settings)
        // Expose the notification service for batch completion notifications
        notificationService = controller.notificationService
        coordinator.activeSettings = settings
        coordinator.startDetectionEventLoop(controller)
    }

    /// Tear down the detection controller and stop the coordinator event loop.
    func disableDetection(coordinator: AppCoordinator) {
        coordinator.stopDetectionEventLoop()
        coordinator.activeSettings = nil
        detectionController?.teardown()
        detectionController = nil
        // NotificationService remains accessible if already set (for batch notifications)
    }

    func seedIfNeeded(coordinator: AppCoordinator) async {
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

        await coordinator.sessionRepository.seedSession(
            id: Self.notesSmokeSessionID,
            records: transcript,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID)
                    ?? TemplateStore.builtInTemplates.first!
            ),
            title: "UI Test Discovery Call"
        )
        await coordinator.loadHistory()
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
