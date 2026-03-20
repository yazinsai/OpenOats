import AppKit
import Foundation
import Observation
import os
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

private let logger = Logger(subsystem: "com.openoats.app", category: "MeetingDetection")

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

    // MARK: - Meeting Detection

    /// Retained reference to the active settings for detection callbacks.
    private(set) var activeSettings: AppSettings?

    /// The meeting detector actor (mic listener + process scanner).
    private(set) var meetingDetector: MeetingDetector?

    /// Notification service for prompting the user.
    private(set) var notificationService: NotificationService?

    /// The long-running task that listens for detection events.
    private var detectionTask: Task<Void, Never>?

    /// Task monitoring silence timeout during detected sessions.
    private var silenceCheckTask: Task<Void, Never>?

    /// Observer token for system sleep notifications.
    private var sleepObserver: Any?

    /// Timestamp of the last utterance, used for silence timeout.
    private var lastUtteranceAt: Date?

    /// Sessions the user dismissed via "Not a Meeting" (by detected app bundle ID).
    /// Cleared on app restart. Prevents re-prompting for the same app within a session.
    private var dismissedEvents: Set<String> = []

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

        // Start silence monitoring for auto-detected sessions
        if metadata.detectionContext?.signal != nil,
           case .appLaunched = metadata.detectionContext?.signal {
            startSilenceMonitoring()
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
        if let settings, settings.saveAudioRecording {
            await audioRecorder?.finalizeRecording()
        }

        // 7. Update UI state + refresh history so Notes window sees the new session
        lastEndedSession = index
        sessionTemplateSnapshot = nil
        await loadHistory()

        // 8. Stop silence monitoring
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        lastUtteranceAt = nil
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

    // MARK: - Meeting Detection Setup

    /// Initialize and start the meeting detection system.
    func setupMeetingDetection(settings: AppSettings) {
        guard meetingDetector == nil else { return }
        activeSettings = settings

        let detector = MeetingDetector(
            customBundleIDs: settings.customMeetingAppBundleIDs
        )
        meetingDetector = detector

        let service = NotificationService()
        notificationService = service

        // Wire notification callbacks
        service.onAccept = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionAccepted()
            }
        }

        service.onNotAMeeting = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionNotAMeeting()
            }
        }

        service.onDismiss = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionDismissed()
            }
        }

        service.onTimeout = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleDetectionTimeout()
            }
        }

        // Start listening for detection events
        detectionTask = Task { [weak self] in
            await detector.start()

            for await event in detector.events {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch event {
                case .detected(let app):
                    await self.handleMeetingDetected(app: app)
                case .ended:
                    await self.handleMeetingEnded()
                }
            }
        }

        installSleepObserver()

        if settings.detectionLogEnabled {
            logger.info("Detection system started")
        }
    }

    /// Tear down the meeting detection system.
    func teardownMeetingDetection() {
        detectionTask?.cancel()
        detectionTask = nil

        silenceCheckTask?.cancel()
        silenceCheckTask = nil

        Task {
            await meetingDetector?.stop()
        }
        meetingDetector = nil

        notificationService?.cancelPending()
        notificationService = nil

        if let observer = sleepObserver {
            NotificationCenter.default.removeObserver(observer)
            sleepObserver = nil
        }

        dismissedEvents.removeAll()
        activeSettings = nil

        logger.info("Detection system stopped")
    }

    // MARK: - Sleep Observer

    private func installSleepObserver() {
        sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .recording = self.state {
                    if self.activeSettings?.detectionLogEnabled == true {
                        logger.info("System sleep detected, stopping session")
                    }
                    self.handle(.userStopped)
                }
            }
        }
    }

    // MARK: - Silence Monitoring

    /// Start monitoring for silence timeout during an auto-detected session.
    private func startSilenceMonitoring() {
        lastUtteranceAt = Date()
        silenceCheckTask?.cancel()

        silenceCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let timeoutMinutes = self.activeSettings?.silenceTimeoutMinutes ?? 15
                if let lastUtterance = self.lastUtteranceAt {
                    let elapsed = Date().timeIntervalSince(lastUtterance)
                    if elapsed >= Double(timeoutMinutes) * 60.0 {
                        if self.activeSettings?.detectionLogEnabled == true {
                            logger.info("Silence timeout (\(timeoutMinutes)m), stopping")
                        }
                        if case .recording = self.state {
                            self.handle(.userStopped)
                        }
                        break
                    }
                }
            }
        }
    }

    /// Called when a new utterance arrives, resets the silence timer.
    func noteUtterance() {
        lastUtteranceAt = Date()
    }

    // MARK: - Detection Event Handlers

    private func handleMeetingDetected(app: MeetingApp?) async {
        // Don't prompt if already recording
        guard case .idle = state else { return }

        // Don't re-prompt for dismissed apps
        if let bundleID = app?.bundleID, dismissedEvents.contains(bundleID) {
            return
        }

        if activeSettings?.detectionLogEnabled == true {
            logger.info("Detected: \(app?.name ?? "unknown", privacy: .public)")
        }

        let posted = await notificationService?.postMeetingDetected(appName: app?.name) ?? false
        if !posted {
            if activeSettings?.detectionLogEnabled == true {
                logger.debug("Failed to post notification (permission denied?)")
            }
        }
    }

    private func handleMeetingEnded() async {
        // If we're recording an auto-detected session, stop it
        if case .recording(let metadata) = state {
            if case .appLaunched = metadata.detectionContext?.signal {
                if activeSettings?.detectionLogEnabled == true {
                    logger.info("Meeting app exited, stopping session")
                }
                handle(.userStopped)
            }
        }
    }

    private func handleDetectionAccepted() {
        guard case .idle = state else { return }

        Task {
            let app = await meetingDetector?.detectedApp
            let context = DetectionContext(
                signal: app.map { .appLaunched($0) } ?? .audioActivity,
                detectedAt: Date(),
                meetingApp: app,
                calendarEvent: nil
            )
            let metadata = MeetingMetadata(
                detectionContext: context,
                calendarEvent: nil,
                title: app?.name,
                startedAt: Date(),
                endedAt: nil
            )
            self.handle(.userStarted(metadata), settings: self.activeSettings)
        }
    }

    private func handleDetectionNotAMeeting() {
        Task {
            if let app = await meetingDetector?.detectedApp {
                dismissedEvents.insert(app.bundleID)
            }
        }

        if activeSettings?.detectionLogEnabled == true {
            logger.debug("User dismissed as not a meeting")
        }
    }

    private func handleDetectionDismissed() {
        if activeSettings?.detectionLogEnabled == true {
            logger.debug("User dismissed notification")
        }
    }

    private func handleDetectionTimeout() {
        if activeSettings?.detectionLogEnabled == true {
            logger.debug("Notification timed out")
        }
    }

    // MARK: - Evaluate Immediate

    /// Check current state immediately (e.g. on app launch) to see if a meeting is already active.
    func evaluateImmediate() async {
        guard case .idle = state else { return }
        guard let detector = meetingDetector else { return }

        let (micActive, app) = await detector.queryCurrentState()
        if micActive, app != nil {
            await handleMeetingDetected(app: app)
        }
    }
}
