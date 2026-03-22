import AppKit
import CoreAudio
import Foundation
import Observation

@Observable
@MainActor
final class LiveSessionController {
    struct State: Sendable {
        var sessionPhase: MeetingState = .idle
        var liveTranscript: [Utterance] = []
        var volatileYouText = ""
        var volatileThemText = ""
        var suggestions: [Suggestion] = []
        var isGeneratingSuggestions = false
        var batchStatus: BatchTranscriptionEngine.Status = .idle
        var currentError: String?
        var lastStorageError: String?
        var selectedInputDeviceID: AudioDeviceID = 0
        var activeCaptureSettings: CaptureSettings
        var modelDisplayName = ""
        var transcriptionPrompt = ""
        var statusMessage: String?
        var needsDownload = false
        var kbIndexingProgress = ""
        var showLiveTranscript = true
        var lastEndedSession: SessionSummary?
        var lastSessionHasNotes = false
        var audioLevel: Float = 0

        var isRunning: Bool {
            if case .recording = sessionPhase { return true }
            return false
        }

        var recordingStartedAt: Date? {
            if case .recording(let metadata) = sessionPhase {
                return metadata.startedAt
            }
            return nil
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _state: State
    var state: State {
        get { access(keyPath: \.state); return _state }
        set { withMutation(keyPath: \.state) { _state = newValue } }
    }

    let settings: SettingsStore
    let repository: SessionRepository
    let templateStore: TemplateStore
    let transcriptStore: TranscriptStore
    let knowledgeBase: KnowledgeBase
    let suggestionEngine: SuggestionEngine
    let transcriptionEngine: TranscriptionEngine
    let refinementEngine: TranscriptRefinementEngine
    let audioRecorder: AudioRecorder
    let batchEngine: BatchTranscriptionEngine

    var onRepositoryChanged: (@MainActor () async -> Void)?
    var onUtteranceFinalized: (@MainActor (Utterance) -> Void)?

    private var notificationService: NotificationService?

    private var didActivate = false
    private var projectionTask: Task<Void, Never>?
    private var batchStatusTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?

    private var activeSessionHandle: SessionHandle?
    private var pendingWrites = 0
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []

    private var observedUtteranceCount = 0
    private var observedKBFolderPath = ""
    private var observedVoyageAPIKey = ""
    private var observedTranscriptionModel: TranscriptionModel
    private var observedInputDeviceID: AudioDeviceID
    private var previousBatchStatus: BatchTranscriptionEngine.Status = .idle

    init(
        settings: SettingsStore,
        repository: SessionRepository,
        templateStore: TemplateStore,
        transcriptStore: TranscriptStore,
        knowledgeBase: KnowledgeBase,
        suggestionEngine: SuggestionEngine,
        transcriptionEngine: TranscriptionEngine,
        refinementEngine: TranscriptRefinementEngine,
        audioRecorder: AudioRecorder,
        batchEngine: BatchTranscriptionEngine
    ) {
        self.settings = settings
        self.repository = repository
        self.templateStore = templateStore
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.suggestionEngine = suggestionEngine
        self.transcriptionEngine = transcriptionEngine
        self.refinementEngine = refinementEngine
        self.audioRecorder = audioRecorder
        self.batchEngine = batchEngine
        self.observedTranscriptionModel = settings.transcriptionModel
        self.observedInputDeviceID = settings.inputDeviceID
        self._state = State(
            activeCaptureSettings: settings.captureSettings
        )
        refreshProjectedState()
    }

    func activateIfNeeded() async {
        guard !didActivate else { return }
        didActivate = true

        observedKBFolderPath = settings.kbFolderPath
        observedVoyageAPIKey = settings.voyageApiKey

        refreshProjectedState()
        synchronizeDerivedState()
        startProjectionTask()
        startBatchStatusTask()
        startAudioLevelTask()
    }

    func startManualSession() {
        Task { @MainActor in
            await self.startSession(metadata: .manual())
        }
    }

    func startDetectedSession(_ metadata: MeetingMetadata) {
        Task { @MainActor in
            await self.startSession(metadata: metadata)
        }
    }

    func confirmModelDownloadAndStart() {
        transcriptionEngine.downloadConfirmed = true
        startManualSession()
    }

    func stopSession() {
        guard case .recording(let metadata) = state.sessionPhase else { return }
        let nextState = transition(from: state.sessionPhase, on: .userStopped)
        guard nextState != state.sessionPhase else { return }
        state.sessionPhase = nextState

        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor in
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard case .ending = self.state.sessionPhase else { return }
                self.state.sessionPhase = transition(from: self.state.sessionPhase, on: .finalizationTimeout)
            }

            await self.finalizeCurrentSession(metadata: metadata)
            timeoutTask.cancel()
            self.state.sessionPhase = transition(from: self.state.sessionPhase, on: .finalizationComplete)
        }
    }

    func discardSession() {
        guard let activeSessionHandle else { return }
        transcriptionEngine.stop()
        audioRecorder.discardRecording()
        suggestionEngine.clear()
        transcriptStore.clear()
        Task {
            await repository.deleteSession(sessionID: activeSessionHandle.id)
        }
        self.activeSessionHandle = nil
        state.sessionPhase = .idle
        refreshProjectedState()
    }

    func refreshRepositoryState() async {
        guard let sessionID = state.lastEndedSession?.id else { return }
        let session = await repository.loadSession(id: sessionID)
        state.lastSessionHasNotes = session.notes != nil
    }

    private func startProjectionTask() {
        projectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshProjectedState()
                self.synchronizeDerivedState()

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.transcriptStore.utterances
                        _ = self.transcriptStore.volatileYouText
                        _ = self.transcriptStore.volatileThemText
                        _ = self.transcriptStore.conversationState
                        _ = self.knowledgeBase.indexingProgress
                        _ = self.suggestionEngine.suggestions
                        _ = self.suggestionEngine.isGenerating
                        _ = self.transcriptionEngine.isRunning
                        _ = self.transcriptionEngine.assetStatus
                        _ = self.transcriptionEngine.lastError
                        _ = self.transcriptionEngine.needsModelDownload
                        _ = self.settings.llmProvider
                        _ = self.settings.selectedModel
                        _ = self.settings.ollamaLLMModel
                        _ = self.settings.mlxModel
                        _ = self.settings.openAILLMModel
                        _ = self.settings.showLiveTranscript
                        _ = self.settings.kbFolderPath
                        _ = self.settings.voyageApiKey
                        _ = self.settings.transcriptionModel
                        _ = self.settings.inputDeviceID
                        _ = self.settings.enableTranscriptRefinement
                        _ = self.settings.enableBatchRefinement
                        _ = self.settings.saveAudioRecording
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func startBatchStatusTask() {
        batchStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let status = await self.batchEngine.status
                self.handleBatchStatus(status)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func startAudioLevelTask() {
        meterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentLevel = self.state.isRunning ? self.transcriptionEngine.audioLevel : 0
                if currentLevel != self.state.audioLevel {
                    self.state.audioLevel = currentLevel
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refreshProjectedState() {
        var next = state
        next.liveTranscript = transcriptStore.utterances
        next.volatileYouText = transcriptStore.volatileYouText
        next.volatileThemText = transcriptStore.volatileThemText
        next.suggestions = suggestionEngine.suggestions
        next.isGeneratingSuggestions = suggestionEngine.isGenerating
        next.currentError = transcriptionEngine.lastError ?? next.lastStorageError
        next.statusMessage = transcriptionEngine.assetStatus
        next.needsDownload = transcriptionEngine.needsModelDownload
        next.kbIndexingProgress = knowledgeBase.indexingProgress
        next.showLiveTranscript = settings.showLiveTranscript
        next.selectedInputDeviceID = settings.inputDeviceID
        next.activeCaptureSettings = settings.captureSettings
        next.transcriptionPrompt = settings.transcriptionModel.downloadPrompt
        next.modelDisplayName = resolveModelDisplayName()
        state = next
    }

    private func synchronizeDerivedState() {
        if settings.kbFolderPath != observedKBFolderPath {
            observedKBFolderPath = settings.kbFolderPath
            if settings.kbFolderPath.isEmpty {
                knowledgeBase.clear()
            } else {
                indexKBIfNeeded()
            }
        }

        if settings.voyageApiKey != observedVoyageAPIKey {
            observedVoyageAPIKey = settings.voyageApiKey
            indexKBIfNeeded()
        }

        if settings.transcriptionModel != observedTranscriptionModel {
            observedTranscriptionModel = settings.transcriptionModel
            transcriptionEngine.refreshModelAvailability()
        }

        if settings.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = settings.inputDeviceID
            if state.isRunning {
                transcriptionEngine.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }

        let utteranceCount = transcriptStore.utterances.count
        if utteranceCount > observedUtteranceCount {
            handleNewUtterances(startingAt: observedUtteranceCount)
        }
        observedUtteranceCount = utteranceCount
    }

    private func resolveModelDisplayName() -> String {
        let model = switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private func indexKBIfNeeded() {
        guard let url = settings.kbFolderURL else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.knowledgeBase.clear()
            await self.knowledgeBase.index(folderURL: url)
            self.refreshProjectedState()
        }
    }

    private func handleNewUtterances(startingAt startIndex: Int) {
        let utterances = transcriptStore.utterances
        guard startIndex < utterances.count, let sessionID = activeSessionHandle?.id else { return }

        for utterance in utterances[startIndex...] {
            onUtteranceFinalized?(utterance)

            if settings.enableTranscriptRefinement {
                Task {
                    await refinementEngine.refine(utterance)
                }
            }

            if utterance.speaker.isRemote {
                suggestionEngine.onThemUtterance(utterance)
                scheduleDelayedRepositoryWrite(for: utterance, sessionID: sessionID)
            } else {
                Task {
                    await repository.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
                }
            }
        }
    }

    private func scheduleDelayedRepositoryWrite(for utterance: Utterance, sessionID: String) {
        pendingWrites += 1
        Task { @MainActor [weak self] in
            defer { self?.finishPendingWrite() }
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }

            let decision = self.suggestionEngine.lastDecision
            let latestSuggestion = self.suggestionEngine.suggestions.first
            let summary = self.transcriptStore.conversationState.shortSummary
            let refinedText = self.transcriptStore.utterances
                .first(where: { $0.id == utterance.id })?
                .refinedText

            let metadata = LiveUtteranceMetadata(
                suggestions: latestSuggestion.map { [$0.text] },
                kbHits: latestSuggestion?.kbHits.map(\.sourceFile),
                suggestionDecision: decision,
                surfacedSuggestionText: decision?.shouldSurface == true ? latestSuggestion?.text : nil,
                conversationStateSummary: summary.isEmpty ? nil : summary,
                refinedText: refinedText
            )

            await self.repository.appendLiveUtterance(
                sessionID: sessionID,
                utterance: utterance,
                metadata: metadata
            )
        }
    }

    private func finishPendingWrite() {
        pendingWrites -= 1
        if pendingWrites == 0 {
            let waiters = pendingWriteWaiters
            pendingWriteWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func awaitPendingWrites() async {
        guard pendingWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            pendingWriteWaiters.append(continuation)
        }
    }

    private func handleBatchStatus(_ status: BatchTranscriptionEngine.Status) {
        guard status != previousBatchStatus else { return }
        previousBatchStatus = status
        state.batchStatus = status

        if case .completed(let sessionID) = status {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !NSApp.isActive {
                    let notificationService = self.notificationService ?? NotificationService()
                    self.notificationService = notificationService
                    await notificationService.postBatchCompleted(sessionID: sessionID)
                }
                await self.exportMeetingMarkdown(sessionID: sessionID)
                await self.onRepositoryChanged?()
                try? await Task.sleep(for: .seconds(3))
                if case .completed = self.state.batchStatus {
                    self.state.batchStatus = .idle
                }
            }
        }
    }

    private func startSession(metadata: MeetingMetadata) async {
        guard !state.isRunning else { return }

        await batchEngine.cancel()
        finalizationTask?.cancel()
        state.lastEndedSession = nil
        state.lastSessionHasNotes = false
        state.lastStorageError = nil
        transcriptStore.clear()
        suggestionEngine.clear()

        let templateSnapshot = resolvedTemplateSnapshot()
        let handle = await repository.startSession(
            config: SessionStartConfig(
                startedAt: metadata.startedAt,
                templateSnapshot: templateSnapshot,
                title: metadata.title,
                meetingApp: metadata.detectionContext?.meetingApp?.name,
                engine: settings.transcriptionModel.rawValue
            )
        )

        if settings.saveAudioRecording || settings.enableBatchRefinement {
            let sessionAudioDirectory = await repository.audioDirectory(for: handle.id)
            audioRecorder.updateDirectory(sessionAudioDirectory)
            audioRecorder.startSession()
            transcriptionEngine.audioRecorder = audioRecorder
        } else {
            transcriptionEngine.audioRecorder = nil
        }

        await transcriptionEngine.start(
            locale: settings.locale,
            inputDeviceID: settings.inputDeviceID,
            transcriptionModel: settings.transcriptionModel
        )

        guard transcriptionEngine.isRunning else {
            await repository.deleteSession(sessionID: handle.id)
            refreshProjectedState()
            return
        }

        activeSessionHandle = handle
        state.sessionPhase = transition(from: state.sessionPhase, on: .userStarted(metadata))
        refreshProjectedState()
    }

    private func finalizeCurrentSession(metadata: MeetingMetadata) async {
        guard let handle = activeSessionHandle else { return }
        let sessionID = handle.id

        await transcriptionEngine.finalize()
        if settings.enableTranscriptRefinement {
            await refinementEngine.drain(timeout: .seconds(5))
        }

        await awaitPendingWrites()
        await repository.backfillRefinedText(sessionID: sessionID, from: transcriptStore.utterances)

        let title = transcriptStore.conversationState.currentTopic.isEmpty
            ? metadata.title
            : transcriptStore.conversationState.currentTopic

        await repository.finalizeSession(
            sessionID: sessionID,
            finalMetadata: SessionFinalizeMetadata(
                endedAt: .now,
                title: title,
                meetingApp: metadata.detectionContext?.meetingApp?.name,
                engine: settings.transcriptionModel.rawValue
            )
        )

        if settings.enableBatchRefinement || settings.saveAudioRecording {
            await persistRecordedAudio(sessionID: sessionID)
        }

        let session = await repository.loadSession(id: sessionID)
        state.lastEndedSession = session.summary
        state.lastSessionHasNotes = session.notes != nil
        self.activeSessionHandle = nil

        await exportMeetingMarkdown(sessionID: sessionID)
        await onRepositoryChanged?()

        if settings.enableBatchRefinement {
            Task.detached { [batchEngine, repository, model = settings.batchTranscriptionModel, locale = settings.locale, diarize = settings.enableDiarization, variant = settings.diarizationVariant] in
                await batchEngine.process(
                    sessionID: sessionID,
                    model: model,
                    locale: locale,
                    sessionRepository: repository,
                    enableDiarization: diarize,
                    diarizationVariant: variant
                )
            }
        }

        refreshProjectedState()
    }

    private func persistRecordedAudio(sessionID: String) async {
        let wantsBatch = settings.enableBatchRefinement
        let wantsExport = settings.saveAudioRecording

        if wantsBatch && wantsExport {
            let tempURLs = audioRecorder.tempFileURLs()
            let anchorsData = audioRecorder.timingAnchors()
            let fm = FileManager.default

            let copiedMic: URL?
            if let micSource = tempURLs.mic, fm.fileExists(atPath: micSource.path) {
                let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("batch_mic_\(sessionID).caf")
                try? fm.copyItem(at: micSource, to: destination)
                copiedMic = destination
            } else {
                copiedMic = nil
            }

            let copiedSys: URL?
            if let sysSource = tempURLs.sys, fm.fileExists(atPath: sysSource.path) {
                let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("batch_sys_\(sessionID).caf")
                try? fm.copyItem(at: sysSource, to: destination)
                copiedSys = destination
            } else {
                copiedSys = nil
            }

            await repository.stashAudioForBatch(
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
            await audioRecorder.finalizeRecording()
            return
        }

        if wantsBatch {
            let sealed = audioRecorder.sealForBatch()
            await repository.stashAudioForBatch(
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
            return
        }

        if wantsExport {
            await audioRecorder.finalizeRecording()
        }
    }

    private func resolvedTemplateSnapshot() -> TemplateSnapshot? {
        if let genericTemplate = templateStore.template(for: TemplateStore.genericID) {
            return templateStore.snapshot(of: genericTemplate)
        }
        return TemplateStore.builtInTemplates.first.map(templateStore.snapshot(of:))
    }

    private func exportMeetingMarkdown(sessionID: String) async {
        let detail = await repository.loadSession(id: sessionID)
        _ = MarkdownMeetingWriter.export(
            session: detail,
            outputDirectory: URL(fileURLWithPath: settings.notesFolderPath)
        )
    }
}
