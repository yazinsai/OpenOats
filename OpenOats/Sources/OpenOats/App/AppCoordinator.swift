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
    @ObservationIgnored private let _sessionStore = SessionStore()
    nonisolated var sessionStore: SessionStore { _sessionStore }

    @ObservationIgnored private let _templateStore = TemplateStore()
    nonisolated var templateStore: TemplateStore { _templateStore }

    @ObservationIgnored private let _notesEngine = NotesEngine()
    nonisolated var notesEngine: NotesEngine { _notesEngine }

    @ObservationIgnored private let _transcriptStore = TranscriptStore()
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

    /// Reflects whether a transcription session is currently active (set by ContentView).
    @ObservationIgnored nonisolated(unsafe) private var _isRecording = false
    var isRecording: Bool {
        get { access(keyPath: \.isRecording); return _isRecording }
        set { withMutation(keyPath: \.isRecording) { _isRecording = newValue } }
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

    var transcriptLogger: TranscriptLogger?
    var transcriptionEngine: TranscriptionEngine?
    var refinementEngine: TranscriptRefinementEngine?
    var audioRecorder: AudioRecorder?

    /// The template snapshot frozen at session start (not stop).
    private var sessionTemplateSnapshot: TemplateSnapshot?

    /// Guard against finalization hanging forever.
    private var finalizationTimeoutTask: Task<Void, Never>?

    // MARK: - State Machine

    /// Drive the meeting lifecycle through the state machine, then dispatch side effects.
    func handle(_ event: MeetingEvent, settings: AppSettings? = nil) {
        let oldState = state
        state = transition(from: oldState, on: event)

        // Only dispatch side effects when the state actually changed
        guard state != oldState else { return }

        performSideEffects(for: event, settings: settings)
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
        lastEndedSession = nil
        transcriptStore.clear()

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
            if settings.saveAudioRecording {
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

        // 3. Build sidecar from this session's transcript data
        let sessionID = await sessionStore.currentSessionID ?? "unknown"
        let utteranceCount = transcriptStore.utterances.count
        let title = transcriptStore.conversationState.currentTopic.isEmpty
            ? nil : transcriptStore.conversationState.currentTopic

        let index = SessionIndex(
            id: sessionID,
            startedAt: transcriptStore.utterances.first?.timestamp ?? Date(),
            endedAt: Date(),
            templateSnapshot: sessionTemplateSnapshot,
            title: title,
            utteranceCount: utteranceCount,
            hasNotes: false
        )
        let sidecar = SessionSidecar(index: index, notes: nil)

        // 4. Write sidecar
        await sessionStore.writeSidecar(sidecar)

        // 5. Close JSONL file
        await sessionStore.endSession()

        // 6. Close plain-text archive (after drain so final utterances are captured)
        await transcriptLogger?.endSession()

        // 6b. Merge and encode audio recording (after all audio drained)
        if let settings, settings.saveAudioRecording {
            await audioRecorder?.finalizeRecording()
        }

        // 7. Update UI state + refresh history so Notes window sees the new session
        lastEndedSession = index
        sessionTemplateSnapshot = nil
        await loadHistory()
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
}
