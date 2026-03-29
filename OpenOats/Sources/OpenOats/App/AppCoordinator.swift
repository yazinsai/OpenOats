import Foundation
import Observation

/// Slim coordinator that owns the meeting lifecycle state machine and all shared
/// cross-cutting state (session history, external command queue, detection event loop).
///
/// **What lives here:**
/// - `state` / `handle()` / `performSideEffects()` — canonical MeetingState machine
/// - `sessionHistory` / `lastEndedSession` — shared observable state consumed by multiple views
/// - External command queue — bridges deep links and menu-bar actions to the live session
/// - Detection event loop — maps MeetingDetectionController events to state machine events
/// - Service references — constructor-injected stores and lazily-set engines
///
/// Side effects are delegated to `LiveSessionController`; this class never touches audio
/// or disk directly.
@Observable
@MainActor
final class AppCoordinator {
    @ObservationIgnored private let _sessionRepository: SessionRepository
    nonisolated var sessionRepository: SessionRepository { _sessionRepository }

    @ObservationIgnored private let _templateStore: TemplateStore
    nonisolated var templateStore: TemplateStore { _templateStore }

    @ObservationIgnored private let _notesEngine: NotesEngine
    nonisolated var notesEngine: NotesEngine { _notesEngine }

    @ObservationIgnored private let _batchTextCleaner = BatchTextCleaner()
    nonisolated var batchTextCleaner: BatchTextCleaner { _batchTextCleaner }

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

    @ObservationIgnored nonisolated(unsafe) private var _batchStatus: BatchAudioTranscriber.Status = .idle
    var batchStatus: BatchAudioTranscriber.Status {
        get { access(keyPath: \.batchStatus); return _batchStatus }
        set { withMutation(keyPath: \.batchStatus) { _batchStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchIsImporting: Bool = false
    var batchIsImporting: Bool {
        get { access(keyPath: \.batchIsImporting); return _batchIsImporting }
        set { withMutation(keyPath: \.batchIsImporting) { _batchIsImporting = newValue } }
    }

    var transcriptionEngine: TranscriptionEngine?
    var liveTranscriptCleaner: LiveTranscriptCleaner?
    var audioRecorder: AudioRecorder?
    var batchAudioTranscriber: BatchAudioTranscriber?

    @ObservationIgnored nonisolated(unsafe) private var _knowledgeBase: KnowledgeBase?
    nonisolated var knowledgeBase: KnowledgeBase? {
        get { _knowledgeBase }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionEngine: SuggestionEngine?
    nonisolated var suggestionEngine: SuggestionEngine? {
        get { _suggestionEngine }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastEngine: SidecastEngine?
    nonisolated var sidecastEngine: SidecastEngine? {
        get { _sidecastEngine }
    }

    func setViewServices(
        knowledgeBase: KnowledgeBase,
        suggestionEngine: SuggestionEngine,
        sidecastEngine: SidecastEngine
    ) {
        _knowledgeBase = knowledgeBase
        _suggestionEngine = suggestionEngine
        _sidecastEngine = sidecastEngine
    }

    /// The template snapshot frozen at session start (not stop).
    var sessionTemplateSnapshot: TemplateSnapshot?

    /// Guard against finalization hanging forever.
    private var finalizationTimeoutTask: Task<Void, Never>?

    /// Retained reference to the active settings for side effects.
    var activeSettings: AppSettings?

    /// The live session controller that handles all session side effects.
    weak var liveSessionController: LiveSessionController?

    /// Task consuming detection controller events.
    private var detectionEventTask: Task<Void, Never>?

    init(
        sessionRepository: SessionRepository = SessionRepository(),
        templateStore: TemplateStore = TemplateStore(),
        notesEngine: NotesEngine = NotesEngine(),
        transcriptStore: TranscriptStore = TranscriptStore()
    ) {
        self._sessionRepository = sessionRepository
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
            Task { await liveSessionController?.startTranscription(metadata: metadata, settings: settings) }

        case .userStopped:
            finalizationTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                handle(.finalizationTimeout)
            }
            Task {
                await liveSessionController?.finalizeCurrentSession(settings: settings)
                finalizationTimeoutTask?.cancel()
                finalizationTimeoutTask = nil
                handle(.finalizationComplete)
            }

        case .userDiscarded:
            Task { liveSessionController?.discardSession() }

        case .finalizationComplete:
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil

        case .finalizationTimeout:
            finalizationTimeoutTask = nil
        }
    }

    // MARK: - History

    /// Load session history from sidecars (lightweight index only).
    func loadHistory() async {
        sessionHistory = await sessionRepository.listSessions()
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
                    if case .appLaunched(let app) = metadata.detectionContext?.signal {
                        controller.startSilenceMonitoring()
                        controller.startAppExitMonitoring(bundleID: app.bundleID)
                    }
                    self.handle(.userStarted(metadata), settings: self.activeSettings)
                case .meetingAppExited:
                    if case .recording(let meta) = self.state,
                       case .appLaunched = meta.detectionContext?.signal {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
                        self.handle(.userStopped)
                    }
                case .silenceTimeout:
                    if case .recording = self.state {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
                        self.handle(.userStopped)
                    }
                case .systemSleep:
                    if case .recording = self.state {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
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
