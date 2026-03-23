import Foundation
import Observation
import SwiftUI

enum ExternalCommand: Equatable {
    case startSession
    case stopSession
    case openNotes(sessionID: String?)
}

struct ExternalCommandRequest: Identifiable, Equatable {
    let id: UUID
    let command: ExternalCommand

    init(command: ExternalCommand) {
        self.id = UUID()
        self.command = command
    }
}

/// Shared state coordinator injected into all window scenes.
/// Bridges the main window (transcription) and Notes window (history + generation).
/// Owns TranscriptStore, TranscriptLogger, TranscriptionEngine, and the recording lifecycle.
@Observable
@MainActor
final class AppCoordinator {
    @ObservationIgnored private let _sessionStore: SessionStore
    nonisolated var sessionStore: SessionStore { _sessionStore }

    @ObservationIgnored private let _templateStore: TemplateStore
    nonisolated var templateStore: TemplateStore { _templateStore }

    @ObservationIgnored private let _notesEngine: NotesEngine
    nonisolated var notesEngine: NotesEngine { _notesEngine }

    @ObservationIgnored private let _cleanupEngine = TranscriptCleanupEngine()
    nonisolated var cleanupEngine: TranscriptCleanupEngine { _cleanupEngine }

    @ObservationIgnored private let _transcriptStore: TranscriptStore
    nonisolated var transcriptStore: TranscriptStore { _transcriptStore }

    @ObservationIgnored nonisolated(unsafe) private var _selectedTemplate: MeetingTemplate?
    var selectedTemplate: MeetingTemplate? {
        get { access(keyPath: \.selectedTemplate); return _selectedTemplate }
        set { withMutation(keyPath: \.selectedTemplate) { _selectedTemplate = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastEndedSession: SessionIndex?
    var lastEndedSession: SessionIndex? {
        get { access(keyPath: \.lastEndedSession); return _lastEndedSession }
        set { withMutation(keyPath: \.lastEndedSession) { _lastEndedSession = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _pendingExternalCommand: ExternalCommandRequest?
    var pendingExternalCommand: ExternalCommandRequest? {
        get { access(keyPath: \.pendingExternalCommand); return _pendingExternalCommand }
        set { withMutation(keyPath: \.pendingExternalCommand) { _pendingExternalCommand = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _requestedSessionSelectionID: String?
    var requestedSessionSelectionID: String? {
        get { access(keyPath: \.requestedSessionSelectionID); return _requestedSessionSelectionID }
        set { withMutation(keyPath: \.requestedSessionSelectionID) { _requestedSessionSelectionID = newValue } }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    @ObservationIgnored nonisolated(unsafe) private var _sessionHistory: [SessionIndex] = []
    private(set) var sessionHistory: [SessionIndex] {
        get { access(keyPath: \.sessionHistory); return _sessionHistory }
        set { withMutation(keyPath: \.sessionHistory) { _sessionHistory = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _state: MeetingState = .idle
    private(set) var state: MeetingState {
        get { access(keyPath: \.state); return _state }
        set { withMutation(keyPath: \.state) { _state = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastStorageError: String?
    var lastStorageError: String? {
        get { access(keyPath: \.lastStorageError); return _lastStorageError }
        set { withMutation(keyPath: \.lastStorageError) { _lastStorageError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchStatus: BatchTranscriptionEngine.Status = .idle
    var batchStatus: BatchTranscriptionEngine.Status {
        get { access(keyPath: \.batchStatus); return _batchStatus }
        set { withMutation(keyPath: \.batchStatus) { _batchStatus = newValue } }
    }

    var transcriptLogger: TranscriptLogger?
    var transcriptionEngine: TranscriptionEngine?
    var refinementEngine: TranscriptRefinementEngine?
    var audioRecorder: AudioRecorder?
    var batchEngine: BatchTranscriptionEngine?

    @ObservationIgnored nonisolated(unsafe) private var _knowledgeBase: KnowledgeBase?
    nonisolated var knowledgeBase: KnowledgeBase? {
        get { _knowledgeBase }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionEngine: SuggestionEngine?
    nonisolated var suggestionEngine: SuggestionEngine? {
        get { _suggestionEngine }
    }

    func setViewServices(knowledgeBase: KnowledgeBase, suggestionEngine: SuggestionEngine) {
        _knowledgeBase = knowledgeBase
        _suggestionEngine = suggestionEngine
    }

    /// The template snapshot frozen at session start (not stop).
    private var sessionTemplateSnapshot: TemplateSnapshot?

    /// Guard against finalization hanging forever.
    private var finalizationTimeoutTask: Task<Void, Never>?

    /// Retained reference to the active settings for side effects.
    var activeSettings: AppSettings?

    /// Task consuming detection controller events.
    private var detectionEventTask: Task<Void, Never>?

    init(
        sessionStore: SessionStore = SessionStore(),
        templateStore: TemplateStore = TemplateStore(),
        notesEngine: NotesEngine = NotesEngine(),
        transcriptStore: TranscriptStore = TranscriptStore()
    ) {
        self._sessionStore = sessionStore
        self._templateStore = templateStore
        self._notesEngine = notesEngine
        self._transcriptStore = transcriptStore
    }

    // MARK: - State Machine

    /// Drive the meeting lifecycle through the state machine, then dispatch side effects.
    func handle(_ event: MeetingEvent, settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? activeSettings

        let oldState = state
        state = transition(from: oldState, on: event)

        // Only dispatch side effects when the state actually changed
        guard state != oldState else { return }

        performSideEffects(for: event, settings: resolvedSettings)
    }

    // MARK: - Side Effects

    private func performSideEffects(for event: MeetingEvent, settings: AppSettings?) {
        switch event {
        case .userStarted(let metadata):
            Task {
                await startTranscription(metadata: metadata, settings: settings)
            }

        case .userStopped:
            finalizationTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                handle(.finalizationTimeout)
            }
            Task {
                await finalizeCurrentSession(settings: settings)
                finalizationTimeoutTask?.cancel()
                finalizationTimeoutTask = nil
                handle(.finalizationComplete)
            }

        case .userDiscarded:
            Task {
                transcriptionEngine?.stop()
                audioRecorder?.discardRecording()
                await transcriptLogger?.endSession()
                transcriptStore.clear()
                await sessionStore.endSession()
            }

        case .finalizationComplete:
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil

        case .finalizationTimeout:
            finalizationTimeoutTask = nil
        }
    }

    // MARK: - Transcription Lifecycle

    private func startTranscription(metadata: MeetingMetadata, settings: AppSettings?) async {
        // Live session preempts any running batch transcription
        if let batchEngine {
            await batchEngine.cancel()
        }

        lastEndedSession = nil
        lastStorageError = nil
        transcriptStore.clear()

        // Wire storage error reporting so UI can surface write failures
        await sessionStore.setWriteErrorHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastStorageError = message
            }
        }

        // Freeze template choice at start time
        if let template = selectedTemplate {
            sessionTemplateSnapshot = templateStore.snapshot(of: template)
        } else if let generic = templateStore.template(for: TemplateStore.genericID) {
            sessionTemplateSnapshot = templateStore.snapshot(of: generic)
        } else {
            sessionTemplateSnapshot = nil
        }

        let templateID = selectedTemplate?.id
        await sessionStore.startSession(templateID: templateID)
        await transcriptLogger?.startSession()

        if let settings {
            if settings.saveAudioRecording || settings.enableBatchRefinement {
                audioRecorder?.startSession()
                transcriptionEngine?.audioRecorder = audioRecorder
            } else {
                transcriptionEngine?.audioRecorder = nil
            }

            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                transcriptionModel: settings.transcriptionModel
            )
        }
    }

    private func finalizeCurrentSession(settings: AppSettings? = nil) async {
        // 1. Drain audio buffers (flush final speech)
        await transcriptionEngine?.finalize()

        // 1b. Drain pending refinements (5-second timeout)
        if let settings, settings.enableTranscriptRefinement {
            await refinementEngine?.drain(timeout: .seconds(5))
        }

        // 2. Drain delayed JSONL writes
        await sessionStore.awaitPendingWrites()

        // 2b. Backfill refined text into JSONL from TranscriptStore
        // The 5-second delayed writes often miss refinedText because LLM calls take longer.
        // By now both the refinement engine and pending writes have drained, so the
        // TranscriptStore has the final refined text for all utterances.
        let utterancesSnapshot = transcriptStore.utterances
        await sessionStore.backfillRefinedText(from: utterancesSnapshot)

        // 3. Build sidecar from this session's transcript data
        let sessionID = await sessionStore.currentSessionID ?? "unknown"
        let utteranceCount = transcriptStore.utterances.count
        let title = transcriptStore.conversationState.currentTopic.isEmpty
            ? nil : transcriptStore.conversationState.currentTopic

        // Extract meeting app name from state machine metadata (available in .ending state)
        let meetingAppName: String?
        if case .ending(let metadata) = state {
            meetingAppName = metadata.detectionContext?.meetingApp?.name
        } else {
            meetingAppName = nil
        }

        // Capture the ASR engine name from current settings
        let engineName = settings?.transcriptionModel.rawValue

        let index = SessionIndex(
            id: sessionID,
            startedAt: transcriptStore.utterances.first?.timestamp ?? Date(),
            endedAt: Date(),
            templateSnapshot: sessionTemplateSnapshot,
            title: title,
            utteranceCount: utteranceCount,
            hasNotes: false,
            meetingApp: meetingAppName,
            engine: engineName
        )
        let sidecar = SessionSidecar(index: index, notes: nil)

        // 4. Write sidecar
        await sessionStore.writeSidecar(sidecar)

        // 4b. Generate structured Markdown file from JSONL (has refined text after backfill)
        let jsonlRecords = await sessionStore.loadTranscript(sessionID: sessionID)
        if !jsonlRecords.isEmpty, let settings {
            let outputDir = URL(fileURLWithPath: settings.notesFolderPath)
            MarkdownMeetingWriter.write(
                metadata: .init(from: index),
                records: jsonlRecords,
                outputDirectory: outputDir
            )
        }

        // 5. Close JSONL file
        await sessionStore.endSession()

        // 6. Close plain-text archive (after drain so final utterances are captured)
        await transcriptLogger?.endSession()

        // 6b. Merge and encode audio recording (after all audio drained)
        // If batch refinement is enabled, stash CAFs for offline transcription.
        if let settings, let recorder = audioRecorder {
            let wantsBatch = settings.enableBatchRefinement
            let wantsExport = settings.saveAudioRecording

            if wantsBatch && wantsExport {
                // Both: copy temp CAFs for batch, then let finalizeRecording merge + clean originals
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

                await sessionStore.stashAudioForBatch(
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

                // Now finalize: merges originals to M4A and cleans temp files
                await recorder.finalizeRecording()
            } else if wantsBatch {
                // Batch only: seal and stash, skip merge
                let sealed = recorder.sealForBatch()
                await sessionStore.stashAudioForBatch(
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
                // No finalizeRecording needed — files moved to session subdir
            } else if wantsExport {
                await recorder.finalizeRecording()
            }
        }

        // 7. Update UI state + refresh history so Notes window sees the new session
        lastEndedSession = index
        sessionTemplateSnapshot = nil
        await loadHistory()

        // 8. Kick off batch transcription if enabled
        if let settings, settings.enableBatchRefinement, let batchEngine {
            let batchSessionID = sessionID
            let batchModel = settings.batchTranscriptionModel
            let batchLocale = settings.locale
            let notesDir = URL(fileURLWithPath: settings.notesFolderPath)
            let store = sessionStore
            let diarize = settings.enableDiarization
            let diarizeVariant = settings.diarizationVariant
            Task.detached { [batchEngine] in
                await batchEngine.process(
                    sessionID: batchSessionID,
                    model: batchModel,
                    locale: batchLocale,
                    sessionStore: store,
                    notesDirectory: notesDir,
                    enableDiarization: diarize,
                    diarizationVariant: diarizeVariant
                )
            }
        }
    }

    // MARK: - History

    /// Load session history from sidecars (lightweight index only).
    func loadHistory() async {
        sessionHistory = await sessionStore.loadSessionIndex()
    }

    func queueExternalCommand(_ command: ExternalCommand) {
        pendingExternalCommand = ExternalCommandRequest(command: command)
    }

    func completeExternalCommand(_ requestID: UUID) {
        guard pendingExternalCommand?.id == requestID else { return }
        pendingExternalCommand = nil
    }

    func queueSessionSelection(_ sessionID: String?) {
        requestedSessionSelectionID = sessionID
    }

    func consumeRequestedSessionSelection() -> String? {
        defer { requestedSessionSelectionID = nil }
        return requestedSessionSelectionID
    }

    // MARK: - Detection Event Loop

    /// Start consuming events from the detection controller's stream.
    /// Maps detection events to state machine events.
    func startDetectionEventLoop(_ controller: MeetingDetectionController) {
        activeSettings = controller.activeSettings
        detectionEventTask?.cancel()
        detectionEventTask = Task { [weak self] in
            for await event in controller.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .accepted(let metadata):
                    // Start silence monitoring for auto-detected sessions
                    if case .appLaunched = metadata.detectionContext?.signal {
                        controller.startSilenceMonitoring()
                    }
                    self.handle(.userStarted(metadata), settings: self.activeSettings)
                case .meetingAppExited:
                    if case .recording(let meta) = self.state,
                       case .appLaunched = meta.detectionContext?.signal {
                        controller.stopSilenceMonitoring()
                        self.handle(.userStopped)
                    }
                case .silenceTimeout:
                    if case .recording = self.state {
                        controller.stopSilenceMonitoring()
                        self.handle(.userStopped)
                    }
                case .systemSleep:
                    if case .recording = self.state {
                        controller.stopSilenceMonitoring()
                        self.handle(.userStopped)
                    }
                case .notAMeeting, .dismissed, .timeout:
                    break
                }
            }
        }
    }

    /// Stop consuming detection events.
    func stopDetectionEventLoop() {
        detectionEventTask?.cancel()
        detectionEventTask = nil
    }
}
