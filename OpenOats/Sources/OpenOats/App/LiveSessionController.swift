import Foundation
import Observation
import CoreAudio
import AppKit

/// Published state for the live session, projected by ContentView.
struct LiveSessionState {
    var isRunning: Bool = false
    var sessionPhase: MeetingState = .idle
    var audioLevel: Float = 0
    var liveTranscript: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""
    var suggestions: [Suggestion] = []
    var isGeneratingSuggestions: Bool = false
    var batchStatus: BatchAudioTranscriber.Status = .idle
    var batchIsImporting: Bool = false
    var lastEndedSession: SessionIndex? = nil
    var lastSessionHasNotes: Bool = false
    var kbIndexingProgress: String = ""
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    var needsDownload: Bool = false
    var downloadProgress: Double? = nil
    var downloadDetail: DownloadProgressDetail? = nil
    var transcriptionPrompt: String = ""
    var modelDisplayName: String = ""
    var showLiveTranscript: Bool = true
    var isMicMuted: Bool = false
}

/// Owns all live session side effects: polling, utterance ingestion,
/// settings change tracking, session start/stop, and finalization.
/// ContentView becomes a pure projection of this controller's state.
@Observable
@MainActor
final class LiveSessionController {
    private(set) var state = LiveSessionState()

    private let coordinator: AppCoordinator
    private let container: AppContainer

    // Tracked-change sentinels
    private var observedUtteranceCount = 0
    private var observedIsRunning = false
    private var observedAudioLevel: Float = 0
    private var observedSuggestions: [Suggestion] = []
    private var observedIsGenerating = false
    private var observedKBFolderPath = ""
    private var observedNotesFolderPath = ""
    private var observedVoyageApiKey = ""
    private var observedTranscriptionModel: TranscriptionModel = .parakeetV2
    private var observedInputDeviceID: AudioDeviceID = 0
    private var observedPendingExternalCommandID: UUID?
    /// Tracks the session ID we last handled a batch completion for,
    /// preventing the auto-dismiss → re-poll cycle from re-triggering the notification.
    private var lastNotifiedBatchSessionID: String?

    init(coordinator: AppCoordinator, container: AppContainer) {
        self.coordinator = coordinator
        self.container = container
    }

    // MARK: - Initialization

    /// One-time setup tasks called when the view first appears.
    func performInitialSetup() async {
        await coordinator.sessionRepository.purgeRecentlyDeleted()
    }

    // MARK: - Polling Loop

    /// Call from a `.task` modifier to start the 250ms polling loop.
    func runPollingLoop(settings: AppSettings) async {
        refreshState(settings: settings)
        synchronizeDerivedState(settings: settings)

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))

            // Poll batch engine status (actor-isolated)
            if let engine = coordinator.batchAudioTranscriber {
                let status = await engine.status
                let importing = await engine.isImporting
                if status != .idle || coordinator.batchStatus != .idle {
                    coordinator.batchStatus = status
                    coordinator.batchIsImporting = importing

                    if case .completed(let sid) = status, lastNotifiedBatchSessionID != sid {
                        lastNotifiedBatchSessionID = sid
                        if !NSApp.isActive, let notifService = container.notificationService {
                            await notifService.postBatchCompleted(sessionID: sid)
                        }
                        await coordinator.loadHistory()

                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            if case .completed = coordinator.batchStatus {
                                coordinator.batchStatus = .idle
                            }
                        }
                    }
                }
            }

            refreshState(settings: settings)
            synchronizeDerivedState(settings: settings)
        }
    }

    // MARK: - Session Actions

    func startSession(settings: AppSettings) {
        coordinator.suggestionEngine?.clear()
        coordinator.sidecastEngine?.clear()
        coordinator.handle(.userStarted(.manual()), settings: settings)
    }

    func stopSession(settings: AppSettings) {
        coordinator.handle(.userStopped, settings: settings)
    }

    func confirmDownloadAndStart(settings: AppSettings) {
        coordinator.transcriptionEngine?.downloadConfirmed = true
        startSession(settings: settings)
    }

    func toggleMicMute() {
        guard let engine = coordinator.transcriptionEngine, engine.isRunning else { return }
        engine.isMicMuted.toggle()
    }

    // MARK: - KB Indexing

    func indexKBIfNeeded(settings: AppSettings) {
        guard let url = settings.kbFolderURL, let kb = coordinator.knowledgeBase else { return }
        Task {
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    // MARK: - External Commands

    func handlePendingExternalCommandIfPossible(settings: AppSettings, openNotesWindow: (() -> Void)?) {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession:
            guard coordinator.transcriptionEngine != nil,
                  (coordinator.suggestionEngine != nil || coordinator.sidecastEngine != nil) else { return }
            if !state.isRunning {
                startSession(settings: settings)
            }
            handled = true
        case .stopSession:
            guard state.isRunning else { return }
            stopSession(settings: settings)
            handled = true
        case .openNotes(let sessionID):
            coordinator.queueSessionSelection(sessionID)
            openNotesWindow?()
            handled = true
        }

        if handled {
            coordinator.completeExternalCommand(request.id)
        }
    }

    // MARK: - Utterance Ingestion (migrated from ContentView)

    private func handleNewUtterance(_ last: Utterance, settings: AppSettings) {
        container.detectionController?.noteUtterance()

        if settings.enableLiveTranscriptCleanup, let engine = coordinator.liveTranscriptCleaner {
            Task {
                await engine.clean(last)
            }
        }

        let sessionID = currentSessionID

        // Trigger the active realtime assistant from either speaker
        switch settings.sidebarMode {
        case .classicSuggestions:
            coordinator.suggestionEngine?.onUtterance(last)
        case .sidecast:
            coordinator.sidecastEngine?.onUtterance(last)
        }

        Task {
            await coordinator.sessionRepository.appendLiveUtterance(
                sessionID: sessionID ?? "",
                utterance: last,
                metadata: LiveUtteranceMetadata(
                    utteranceID: last.id,
                    suggestionEngine: coordinator.suggestionEngine,
                    transcriptStore: coordinator.transcriptStore,
                    isDelayed: true
                )
            )
        }
    }

    /// The current session ID from the repository.
    private var currentSessionID: String? {
        // This is captured at start time and held for the session lifetime.
        _currentSessionID
    }
    private var _currentSessionID: String?

    private func handleNewUtterances(startingAt startIndex: Int, settings: AppSettings) {
        let utterances = coordinator.transcriptStore.utterances
        guard startIndex < utterances.count else { return }

        for utterance in utterances[startIndex...] {
            handleNewUtterance(utterance, settings: settings)
        }
    }

    // MARK: - Transcription Lifecycle (migrated from AppCoordinator)

    func startTranscription(metadata: MeetingMetadata, settings: AppSettings?) async {
        if let batchAudioTranscriber = coordinator.batchAudioTranscriber {
            await batchAudioTranscriber.cancel()
        }

        coordinator.lastEndedSession = nil
        coordinator.lastStorageError = nil
        coordinator.transcriptStore.clear()

        await coordinator.sessionRepository.setWriteErrorHandler { [weak coordinator] message in
            Task { @MainActor [weak coordinator] in
                coordinator?.lastStorageError = message
            }
        }

        // Freeze template choice at start time
        if let template = coordinator.selectedTemplate {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: template)
        } else if let generic = coordinator.templateStore.template(for: TemplateStore.genericID) {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: generic)
        } else {
            coordinator.sessionTemplateSnapshot = nil
        }

        // Configure notes folder for mirroring
        if let settings {
            let notesURL = URL(fileURLWithPath: settings.notesFolderPath)
            await coordinator.sessionRepository.setNotesFolderPath(notesURL)
        }

        let templateID = coordinator.selectedTemplate?.id
        let handle = await coordinator.sessionRepository.startSession(
            config: SessionStartConfig(
                templateID: templateID,
                templateSnapshot: coordinator.sessionTemplateSnapshot
            )
        )
        _currentSessionID = handle.sessionID

        if let settings {
            if settings.saveAudioRecording || settings.enableBatchRetranscription {
                coordinator.audioRecorder?.startSession()
                coordinator.transcriptionEngine?.audioRecorder = coordinator.audioRecorder
            } else {
                coordinator.transcriptionEngine?.audioRecorder = nil
            }

            await coordinator.transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                transcriptionModel: settings.transcriptionModel
            )
        }
    }

    func finalizeCurrentSession(settings: AppSettings?) async {
        // 1. Drain audio buffers
        await coordinator.transcriptionEngine?.finalize()

        // 1b. Drain pending cleanups
        if let settings, settings.enableLiveTranscriptCleanup {
            await coordinator.liveTranscriptCleaner?.drain(timeout: .seconds(5))
        }

        // 2. Drain delayed JSONL writes
        await coordinator.sessionRepository.awaitPendingWrites()

        // 3. Build finalization metadata
        let sessionID: String
        if let id = _currentSessionID {
            sessionID = id
        } else if let id = await coordinator.sessionRepository.getCurrentSessionID() {
            sessionID = id
        } else {
            sessionID = "unknown"
        }
        let utterancesSnapshot = coordinator.transcriptStore.utterances
        let utteranceCount = utterancesSnapshot.count
        let title = coordinator.transcriptStore.conversationState.currentTopic.isEmpty
            ? nil : coordinator.transcriptStore.conversationState.currentTopic

        let meetingAppName: String?
        if case .ending(let metadata) = coordinator.state {
            meetingAppName = metadata.detectionContext?.meetingApp?.name
        } else {
            meetingAppName = nil
        }

        let engineName = settings?.transcriptionModel.rawValue
        let transcriptionLanguage: String? = {
            guard let locale = settings?.transcriptionLocale, !locale.isEmpty else { return nil }
            return locale
        }()

        // 4. Finalize: closes file handle, backfills cleaned text, writes session.json
        await coordinator.sessionRepository.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: utteranceCount,
                title: title,
                language: transcriptionLanguage,
                meetingApp: meetingAppName,
                engine: engineName,
                templateSnapshot: coordinator.sessionTemplateSnapshot,
                utterances: utterancesSnapshot
            )
        )

        // 5. Build index for UI state
        let index = SessionIndex(
            id: sessionID,
            startedAt: utterancesSnapshot.first?.timestamp ?? Date(),
            endedAt: Date(),
            templateSnapshot: coordinator.sessionTemplateSnapshot,
            title: title,
            utteranceCount: utteranceCount,
            hasNotes: false,
            language: transcriptionLanguage,
            meetingApp: meetingAppName,
            engine: engineName
        )

        // 5b. Fire webhook if configured
        if let settings {
            WebhookService.fireIfEnabled(
                settings: settings,
                sessionIndex: index,
                utterances: utterancesSnapshot
            )
        }

        // 6. Handle audio recording
        if let settings, let recorder = coordinator.audioRecorder {
            let wantsBatch = settings.enableBatchRetranscription
            let wantsExport = settings.saveAudioRecording

            if wantsBatch && wantsExport {
                let tempURLs = recorder.tempFileURLs()
                let anchorsData = recorder.timingAnchors()
                let fm = FileManager.default

                let copiedMic: URL?
                if let micSrc = tempURLs.mic, fm.fileExists(atPath: micSrc.path) {
                    let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("batch_mic_\(sessionID).caf")
                    try? fm.copyItem(at: micSrc, to: dst)
                    copiedMic = dst
                } else {
                    copiedMic = nil
                }

                let copiedSys: URL?
                if let sysSrc = tempURLs.sys, fm.fileExists(atPath: sysSrc.path) {
                    let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("batch_sys_\(sessionID).caf")
                    try? fm.copyItem(at: sysSrc, to: dst)
                    copiedSys = dst
                } else {
                    copiedSys = nil
                }

                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: copiedMic,
                    sysURL: copiedSys,
                    anchors: BatchAnchors(
                        micStartDate: anchorsData.micStartDate,
                        sysStartDate: anchorsData.sysStartDate,
                        micAnchors: anchorsData.micAnchors,
                        sysAnchors: anchorsData.sysAnchors
                    )
                )

                await recorder.finalizeRecording()
            } else if wantsBatch {
                let sealed = recorder.sealForBatch()
                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: sealed.mic,
                    sysURL: sealed.sys,
                    anchors: BatchAnchors(
                        micStartDate: sealed.micStartDate,
                        sysStartDate: sealed.sysStartDate,
                        micAnchors: sealed.micAnchors,
                        sysAnchors: sealed.sysAnchors
                    )
                )
            } else if wantsExport {
                await recorder.finalizeRecording()
            }
        }

        // 7. Update UI state + refresh history
        coordinator.lastEndedSession = index
        coordinator.sessionTemplateSnapshot = nil
        _currentSessionID = nil
        await coordinator.loadHistory()

        // 8. Kick off batch transcription if enabled
        if let settings, settings.enableBatchRetranscription, let batchAudioTranscriber = coordinator.batchAudioTranscriber {
            let batchSessionID = sessionID
            let batchModel = settings.batchTranscriptionModel
            let batchLocale = settings.locale
            let notesDir = URL(fileURLWithPath: settings.notesFolderPath)
            let repo = coordinator.sessionRepository
            let diarize = settings.enableDiarization
            let diarizeVariant = settings.diarizationVariant
            Task.detached { [batchAudioTranscriber] in
                await batchAudioTranscriber.process(
                    sessionID: batchSessionID,
                    model: batchModel,
                    locale: batchLocale,
                    sessionRepository: repo,
                    notesDirectory: notesDir,
                    enableDiarization: diarize,
                    diarizationVariant: diarizeVariant
                )
            }
        }
    }

    func discardSession() {
        coordinator.transcriptionEngine?.stop()
        coordinator.audioRecorder?.discardRecording()
        coordinator.transcriptStore.clear()
        _currentSessionID = nil
        Task {
            await coordinator.sessionRepository.endSession()
        }
    }

    // MARK: - State Refresh

    @MainActor
    private func refreshState(settings: AppSettings) {
        let lastEndedSession = coordinator.lastEndedSession
        let lastSessionHasNotes = lastEndedSession.flatMap { lastSession in
            coordinator.sessionHistory.first { $0.id == lastSession.id }?.hasNotes
        } ?? false

        let activeModelRaw = switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }

        var next = LiveSessionState()
        let sidebarSuggestions: [Suggestion]
        let sidebarGenerating: Bool
        switch settings.sidebarMode {
        case .classicSuggestions:
            sidebarSuggestions = coordinator.suggestionEngine?.suggestions ?? []
            sidebarGenerating = coordinator.suggestionEngine?.isGenerating ?? false
        case .sidecast:
            sidebarSuggestions = coordinator.sidecastEngine?.suggestions ?? []
            sidebarGenerating = coordinator.sidecastEngine?.isGenerating ?? false
        }
        next.isRunning = coordinator.transcriptionEngine?.isRunning ?? false
        next.sessionPhase = coordinator.state
        next.audioLevel = next.isRunning ? (coordinator.transcriptionEngine?.audioLevel ?? 0) : 0
        next.liveTranscript = coordinator.transcriptStore.utterances
        next.volatileYouText = coordinator.transcriptStore.volatileYouText
        next.volatileThemText = coordinator.transcriptStore.volatileThemText
        next.suggestions = sidebarSuggestions
        next.isGeneratingSuggestions = sidebarGenerating
        next.batchStatus = coordinator.batchStatus
        next.batchIsImporting = coordinator.batchIsImporting
        next.lastEndedSession = lastEndedSession
        next.lastSessionHasNotes = lastSessionHasNotes
        next.kbIndexingProgress = coordinator.knowledgeBase?.indexingProgress ?? ""
        next.statusMessage = coordinator.transcriptionEngine?.assetStatus
        next.errorMessage = coordinator.transcriptionEngine?.lastError
        next.needsDownload = coordinator.transcriptionEngine?.needsModelDownload ?? false
        next.downloadProgress = coordinator.transcriptionEngine?.downloadProgress
        next.downloadDetail = coordinator.transcriptionEngine?.downloadDetail
        next.transcriptionPrompt = settings.transcriptionModel.downloadPrompt
        next.modelDisplayName = activeModelRaw.split(separator: "/").last.map(String.init) ?? activeModelRaw
        next.showLiveTranscript = settings.showLiveTranscript
        next.isMicMuted = coordinator.transcriptionEngine?.isMicMuted ?? false

        state = next
    }

    // MARK: - Derived State Synchronization

    /// Callback for MiniBar show/hide — set by the view.
    var onRunningStateChanged: ((_ isRunning: Bool) -> Void)?
    /// Called when minibar-visible state changes during recording.
    var onMiniBarContentUpdate: (() -> Void)?

    /// Callback for opening the notes window — set by the view.
    var openNotesWindow: (() -> Void)?

    @MainActor
    private func synchronizeDerivedState(settings: AppSettings) {
        let currentState = state

        if settings.kbFolderPath != observedKBFolderPath {
            observedKBFolderPath = settings.kbFolderPath
            if settings.kbFolderPath.isEmpty {
                coordinator.knowledgeBase?.clear()
            } else {
                indexKBIfNeeded(settings: settings)
            }
        }

        if settings.notesFolderPath != observedNotesFolderPath {
            observedNotesFolderPath = settings.notesFolderPath
            let url = URL(fileURLWithPath: settings.notesFolderPath)
            Task {
                await coordinator.sessionRepository.setNotesFolderPath(url)
            }
            coordinator.audioRecorder?.updateDirectory(url)
        }

        if settings.voyageApiKey != observedVoyageApiKey {
            observedVoyageApiKey = settings.voyageApiKey
            indexKBIfNeeded(settings: settings)
        }

        if settings.transcriptionModel != observedTranscriptionModel {
            observedTranscriptionModel = settings.transcriptionModel
            coordinator.transcriptionEngine?.refreshModelAvailability()
        }

        if settings.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = settings.inputDeviceID
            if currentState.isRunning {
                Task {
                    coordinator.transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
                }
            }
        }

        let utteranceCount = currentState.liveTranscript.count
        if utteranceCount > observedUtteranceCount {
            handleNewUtterances(startingAt: observedUtteranceCount, settings: settings)
        }
        observedUtteranceCount = utteranceCount

        if currentState.isRunning != observedIsRunning {
            observedIsRunning = currentState.isRunning
            onRunningStateChanged?(currentState.isRunning)
        }

        // Refresh minibar content only when visible state changed
        if currentState.isRunning {
            let levelChanged = abs(currentState.audioLevel - observedAudioLevel) > 0.01
            let suggestionsChanged = currentState.suggestions.map(\.id) != observedSuggestions.map(\.id)
            let generatingChanged = currentState.isGeneratingSuggestions != observedIsGenerating

            if levelChanged || suggestionsChanged || generatingChanged {
                observedAudioLevel = currentState.audioLevel
                observedSuggestions = currentState.suggestions
                observedIsGenerating = currentState.isGeneratingSuggestions
                onMiniBarContentUpdate?()
            }
        }

        let pendingExternalCommandID = coordinator.pendingExternalCommand?.id
        if pendingExternalCommandID != observedPendingExternalCommandID {
            observedPendingExternalCommandID = pendingExternalCommandID
            handlePendingExternalCommandIfPossible(settings: settings, openNotesWindow: openNotesWindow)
        }
    }
}
