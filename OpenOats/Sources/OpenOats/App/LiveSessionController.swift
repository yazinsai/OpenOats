import Foundation
import Observation
import CoreAudio
import AppKit

/// Published state for the live session, projected by ContentView.
/// Declared as @Observable class so SwiftUI tracks each property individually,
/// preventing a full view-tree re-render whenever any single field changes.
@Observable
final class LiveSessionState {
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
    var kbIndexingStatus: KnowledgeBaseIndexingStatus = .idle
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    var matchedCalendarEvent: CalendarEvent? = nil
    var needsDownload: Bool = false
    var downloadProgress: Double? = nil
    var downloadDetail: DownloadProgressDetail? = nil
    var transcriptionPrompt: String = ""
    var modelDisplayName: String = ""
    var showLiveTranscript: Bool = true
    var isMicMuted: Bool = false
    /// The user's live scratchpad text for the active session.
    var scratchpadText: String = ""
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

    private var downloadTask: Task<Void, Never>?
    private var scratchpadSaveTask: Task<Void, Never>?
    private var pendingInitialScratchpad: String?

    // Tracked-change sentinels
    private var observedUtteranceCount = 0
    private var observedIsRunning = false
    private var observedAudioLevel: Float = 0
    private var observedSuggestions: [Suggestion] = []
    private var observedIsGenerating = false
    private var observedKBFolderPath: String?
    private var observedNotesFolderPath = ""
    private var observedEmbeddingProvider: EmbeddingProvider?
    private var observedVoyageApiKey: String?
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

    /// Call from a `.task` modifier to start the polling loop.
    /// Polls at 250ms while recording for responsive UI, and at 2s while idle
    /// to minimize observation churn and SwiftUI re-render cycles.
    func runPollingLoop(settings: AppSettings) async {
        refreshState(settings: settings)
        synchronizeDerivedState(settings: settings)

        while !Task.isCancelled {
            let isActive = coordinator.transcriptionEngine?.isRunning == true
                || coordinator.batchStatus != .idle
                || coordinator.knowledgeBase?.indexingStatus.needsFrequentPolling == true
            try? await Task.sleep(for: isActive ? .milliseconds(250) : .seconds(2))

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

    func startSession(
        settings: AppSettings,
        calendarEventOverride: CalendarEvent? = nil,
        initialScratchpad: String? = nil
    ) {
        guard !state.isRunning else { return }
        container.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)
        coordinator.suggestionEngine?.clear()
        coordinator.sidecastEngine?.clear()
        let calEvent = calendarEventOverride ?? (settings.calendarIntegrationEnabled
            ? container.calendarManager?.currentEvent()
            : nil)
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Start requested (calendarEvent=\(calEvent == nil ? "no" : "yes"))"
        )
        pendingInitialScratchpad = initialScratchpad?.trimmingCharacters(in: .newlines)
        let metadata = MeetingMetadata.manual(calendarEvent: calEvent)
        coordinator.handle(.userStarted(metadata), settings: settings)
    }

    func stopSession(settings: AppSettings) {
        DiagnosticsSupport.record(category: "meeting", message: "Stop requested")
        coordinator.handle(.userStopped, settings: settings)
    }

    func confirmDownloadAndStart(settings: AppSettings) {
        container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
        coordinator.transcriptionEngine?.downloadConfirmed = true
        startSession(settings: settings)
    }

    func downloadModelOnly(settings: AppSettings) {
        guard downloadTask == nil else { return }
        container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
        downloadTask = Task {
            await coordinator.transcriptionEngine?.downloadModelOnly(
                transcriptionModel: settings.transcriptionModel
            )
            downloadTask = nil
        }
    }

    func toggleMicMute() {
        guard let engine = coordinator.transcriptionEngine, engine.isRunning else { return }
        engine.isMicMuted.toggle()
    }

    /// Update the scratchpad text and schedule a debounced save.
    func updateScratchpad(_ text: String) {
        state.scratchpadText = text
        scratchpadSaveTask?.cancel()
        scratchpadSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let sessionID = _currentSessionID else { return }
            await coordinator.sessionRepository.saveScratchpad(sessionID: sessionID, text: text)
        }
    }

    // MARK: - KB Indexing

    func indexKBIfNeeded(settings: AppSettings) {
        guard let url = settings.kbFolderURL, let kb = coordinator.knowledgeBase else { return }
        Task {
            // TODO: Coalesce repeated startup/settings-triggered reindex requests into a
            // single in-flight task. Today ContentView startup, kbFolderPath changes, and
            // Voyage key changes can all arrive close together and redo the same cold-start scan.
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    func loadKBCacheIfAvailable(settings: AppSettings) {
        guard let url = settings.kbFolderURL, let kb = coordinator.knowledgeBase else { return }
        _ = kb.loadCachedStateIfAvailable(folderURL: url)
    }

    // MARK: - External Commands

    func handlePendingExternalCommandIfPossible(settings: AppSettings, openNotesWindow: (() -> Void)?) {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession(let calendarEvent, let scratchpadSeed):
            container.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)
            guard coordinator.transcriptionEngine != nil,
                  (coordinator.suggestionEngine != nil || coordinator.sidecastEngine != nil) else { return }
            if !state.isRunning {
                startSession(
                    settings: settings,
                    calendarEventOverride: calendarEvent,
                    initialScratchpad: scratchpadSeed
                )
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

        // Configure notes folder for mirroring (prefer security-scoped bookmark)
        if let settings {
            if let resolvedURL = settings.resolveNotesFolderBookmark() {
                await coordinator.sessionRepository.setNotesFolderPath(resolvedURL, securityScoped: true)
                coordinator.audioRecorder?.updateDirectory(resolvedURL, securityScoped: true)
            } else {
                let notesURL = URL(fileURLWithPath: settings.notesFolderPath)
                await coordinator.sessionRepository.setNotesFolderPath(notesURL)
                coordinator.audioRecorder?.updateDirectory(notesURL)
            }
        }

        let templateID = coordinator.selectedTemplate?.id
        let startConfig = SessionStartConfig(
            templateID: templateID,
            templateSnapshot: coordinator.sessionTemplateSnapshot,
            title: metadata.title ?? metadata.calendarEvent?.title,
            calendarEvent: metadata.calendarEvent
        )
        let handle: SessionHandle
        let reusedAbandonedRow: Bool
        if let resumed = await coordinator.sessionRepository.resumeAbandonedSession(config: startConfig) {
            handle = resumed
            reusedAbandonedRow = true
        } else {
            handle = await coordinator.sessionRepository.startSession(config: startConfig)
            reusedAbandonedRow = false
        }
        _currentSessionID = handle.sessionID
        DiagnosticsSupport.record(
            category: "meeting",
            message: "\(reusedAbandonedRow ? "Reused" : "Started") session \(handle.sessionID) model=\(settings?.transcriptionModel.rawValue ?? "unknown")"
        )
        let initialScratchpad = pendingInitialScratchpad?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInitialScratchpad = nil
        state.scratchpadText = initialScratchpad ?? ""
        if let initialScratchpad, !initialScratchpad.isEmpty {
            await coordinator.sessionRepository.saveScratchpad(sessionID: handle.sessionID, text: initialScratchpad)
        }

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
        // 0. Flush scratchpad
        scratchpadSaveTask?.cancel()
        if let sessionID = _currentSessionID, !state.scratchpadText.isEmpty {
            await coordinator.sessionRepository.saveScratchpad(sessionID: sessionID, text: state.scratchpadText)
        }

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
        let endingMetadata: MeetingMetadata?
        if case .ending(let metadata) = coordinator.state {
            endingMetadata = metadata
        } else {
            endingMetadata = nil
        }
        let metadataTitle = endingMetadata?.title ?? endingMetadata?.calendarEvent?.title
        let title = coordinator.transcriptStore.conversationState.currentTopic.isEmpty
            ? metadataTitle : coordinator.transcriptStore.conversationState.currentTopic
        let meetingAppName = endingMetadata?.detectionContext?.meetingApp?.name

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
                utterances: utterancesSnapshot,
                calendarEvent: endingMetadata?.calendarEvent
            )
        )

        if let settings,
           let event = endingMetadata?.calendarEvent,
           let folderPath = settings.meetingFamilyPreferences(for: event)?.folderPath {
            await coordinator.sessionRepository.updateSessionFolder(sessionID: sessionID, folderPath: folderPath)
        }

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

        // 5c. Export to Apple Notes if configured
        if let settings {
            AppleNotesService.exportIfEnabled(
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
                        sysAnchors: anchorsData.sysAnchors,
                        sysEffectiveSampleRate: anchorsData.sysEffectiveSampleRate
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
                        sysAnchors: sealed.sysAnchors,
                        sysEffectiveSampleRate: sealed.sysEffectiveSampleRate
                    )
                )
            } else if wantsExport {
                await recorder.finalizeRecording()
            }
        }

        // 7. Collapse obviously empty duplicate sessions back into the real meeting session.
        var effectiveIndex = index
        var shouldRunBatchRetranscription = settings?.enableBatchRetranscription == true
        if utteranceCount == 0,
           let mergedSessionID = await coordinator.sessionRepository.reconcileGhostSession(sessionID: sessionID) {
            effectiveIndex = await coordinator.sessionRepository.loadSession(id: mergedSessionID).index
            shouldRunBatchRetranscription = false
            DiagnosticsSupport.record(
                category: "meeting",
                message: "Collapsed empty duplicate session \(sessionID) into \(mergedSessionID)"
            )
        }

        // 8. Update UI state + refresh history
        coordinator.lastEndedSession = effectiveIndex
        coordinator.sessionTemplateSnapshot = nil
        _currentSessionID = nil
        DiagnosticsSupport.record(
            category: "meeting",
            message: "Finalized session \(effectiveIndex.id) utterances=\(utteranceCount) batch=\(shouldRunBatchRetranscription ? "on" : "off")"
        )
        await coordinator.loadHistory()

        // 9. Kick off batch transcription if enabled
        if let settings, shouldRunBatchRetranscription, let batchAudioTranscriber = coordinator.batchAudioTranscriber {
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
        if let sessionID = _currentSessionID {
            DiagnosticsSupport.record(category: "meeting", message: "Discarded session \(sessionID)")
        }
        _currentSessionID = nil
        Task {
            await coordinator.sessionRepository.endSession()
        }
    }

    // MARK: - State Refresh

    /// Assigns `value` to `state[keyPath:]` only when it differs, avoiding spurious
    /// @Observable withMutation notifications that would trigger unnecessary layout passes.
    @inline(__always)
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<LiveSessionState, T>, _ value: T) {
        if state[keyPath: kp] != value { state[keyPath: kp] = value }
    }

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

        let isRunning = coordinator.transcriptionEngine?.isRunning ?? false
        let matchedCalendarEvent: CalendarEvent?
        switch coordinator.state {
        case .recording(let metadata), .ending(let metadata):
            matchedCalendarEvent = metadata.calendarEvent
        case .idle:
            matchedCalendarEvent = nil
        }

        // Use set(_:_:) for all Equatable fields: only fires @Observable withMutation
        // when the value actually changed, preventing spurious layout passes on NSHostingView.
        set(\.isRunning, isRunning)
        set(\.sessionPhase, coordinator.state)
        set(\.audioLevel, isRunning ? (coordinator.transcriptionEngine?.audioLevel ?? 0) : 0)
        set(\.volatileYouText, coordinator.transcriptStore.volatileYouText)
        set(\.volatileThemText, coordinator.transcriptStore.volatileThemText)
        set(\.isGeneratingSuggestions, sidebarGenerating)
        set(\.batchStatus, coordinator.batchStatus)
        set(\.batchIsImporting, coordinator.batchIsImporting)
        if state.lastEndedSession?.id != lastEndedSession?.id { state.lastEndedSession = lastEndedSession }
        set(\.lastSessionHasNotes, lastSessionHasNotes)
        set(\.kbIndexingStatus, coordinator.knowledgeBase?.indexingStatus ?? .idle)
        set(\.statusMessage, coordinator.transcriptionEngine?.assetStatus)
        set(\.errorMessage, coordinator.transcriptionEngine?.lastError)
        set(\.matchedCalendarEvent, matchedCalendarEvent)
        set(\.needsDownload, coordinator.transcriptionEngine?.needsModelDownload ?? false)
        set(\.downloadProgress, coordinator.transcriptionEngine?.downloadProgress)
        set(\.transcriptionPrompt, settings.transcriptionModel.downloadPrompt)
        set(\.modelDisplayName, activeModelRaw.split(separator: "/").last.map(String.init) ?? activeModelRaw)
        set(\.showLiveTranscript, settings.showLiveTranscript)
        set(\.isMicMuted, coordinator.transcriptionEngine?.isMicMuted ?? false)
        // scratchpadText is managed by updateScratchpad(), not refreshed from coordinator
        // downloadDetail is not Equatable; only update when nil-ness changes or download active
        let nextDetail = coordinator.transcriptionEngine?.downloadDetail
        if nextDetail != nil || state.downloadDetail != nil {
            state.downloadDetail = nextDetail
        }

        // Arrays: compare by ID before assigning — array assignment always fires observation.
        let nextTranscript = coordinator.transcriptStore.utterances
        if state.liveTranscript != nextTranscript {
            state.liveTranscript = nextTranscript
        }
        if state.suggestions != sidebarSuggestions {
            state.suggestions = sidebarSuggestions
        }
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

        if let observedKBFolderPath {
            if settings.kbFolderPath != observedKBFolderPath {
                self.observedKBFolderPath = settings.kbFolderPath
                if settings.kbFolderPath.isEmpty {
                    coordinator.knowledgeBase?.clear()
                } else {
                    indexKBIfNeeded(settings: settings)
                }
            }
        } else {
            observedKBFolderPath = settings.kbFolderPath
            if settings.kbFolderPath.isEmpty {
                coordinator.knowledgeBase?.clear()
            } else {
                loadKBCacheIfAvailable(settings: settings)
            }
        }

        if settings.notesFolderPath != observedNotesFolderPath {
            observedNotesFolderPath = settings.notesFolderPath
            if let resolvedURL = settings.resolveNotesFolderBookmark() {
                Task {
                    await coordinator.sessionRepository.setNotesFolderPath(resolvedURL, securityScoped: true)
                }
                coordinator.audioRecorder?.updateDirectory(resolvedURL, securityScoped: true)
            } else {
                let url = URL(fileURLWithPath: settings.notesFolderPath)
                Task {
                    await coordinator.sessionRepository.setNotesFolderPath(url)
                }
                coordinator.audioRecorder?.updateDirectory(url)
            }
        }

        if settings.kbFolderPath.isEmpty {
            observedEmbeddingProvider = nil
            observedVoyageApiKey = nil
        } else {
            if let observedEmbeddingProvider {
                if settings.embeddingProvider != observedEmbeddingProvider {
                    self.observedEmbeddingProvider = settings.embeddingProvider
                    indexKBIfNeeded(settings: settings)
                }
            } else {
                observedEmbeddingProvider = settings.embeddingProvider
            }

            if settings.embeddingProvider == .voyageAI {
                if settings.isSecretLoaded("voyageApiKey") {
                    let voyageApiKey = settings.voyageApiKey
                    if let observedVoyageApiKey {
                        if voyageApiKey != observedVoyageApiKey {
                            self.observedVoyageApiKey = voyageApiKey
                            indexKBIfNeeded(settings: settings)
                        }
                    } else {
                        observedVoyageApiKey = voyageApiKey
                    }
                }
            } else {
                observedVoyageApiKey = nil
            }
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
            let suggestionsChanged = currentState.suggestions != observedSuggestions
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
