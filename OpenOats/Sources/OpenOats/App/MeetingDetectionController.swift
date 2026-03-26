import AppKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.openoats.app", category: "MeetingDetection")

/// One-shot events emitted by the detection controller for consumption by the coordinator.
enum DetectionEvent: Sendable {
    case accepted(MeetingMetadata)
    case notAMeeting(bundleID: String)
    case dismissed
    case timeout
    case meetingAppExited
    case silenceTimeout
    case systemSleep
}

/// Owns the meeting detection lifecycle: mic monitoring, notification prompting,
/// silence timeout, and sleep observation. Exposes an `AsyncStream<DetectionEvent>`
/// consumed exactly once by the coordinator.
@Observable
@MainActor
final class MeetingDetectionController {
    // MARK: - Observable State (for UI)

    @ObservationIgnored nonisolated(unsafe) private var _isEnabled = false
    private(set) var isEnabled: Bool {
        get { access(keyPath: \.isEnabled); return _isEnabled }
        set { withMutation(keyPath: \.isEnabled) { _isEnabled = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _detectedApp: MeetingApp?
    private(set) var detectedApp: MeetingApp? {
        get { access(keyPath: \.detectedApp); return _detectedApp }
        set { withMutation(keyPath: \.detectedApp) { _detectedApp = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isMonitoringSilence = false
    private(set) var isMonitoringSilence: Bool {
        get { access(keyPath: \.isMonitoringSilence); return _isMonitoringSilence }
        set { withMutation(keyPath: \.isMonitoringSilence) { _isMonitoringSilence = newValue } }
    }

    // MARK: - Event Stream

    /// One-shot event stream. Events are consumed exactly once, never replayed.
    let events: AsyncStream<DetectionEvent>
    private let eventContinuation: AsyncStream<DetectionEvent>.Continuation

    // MARK: - Internal State

    /// The meeting detector actor (mic listener + process scanner).
    private(set) var meetingDetector: MeetingDetector?

    /// Notification service for prompting the user.
    private(set) var notificationService: NotificationService?

    /// The long-running task that listens for detection events.
    private var detectionTask: Task<Void, Never>?

    /// Task monitoring silence timeout during detected sessions.
    private var silenceCheckTask: Task<Void, Never>?

    /// Task polling for meeting app process exit during recording.
    private var appExitMonitorTask: Task<Void, Never>?

    /// Observer token for system sleep notifications.
    private var sleepObserver: Any?

    /// Timestamp of the last utterance, used for silence timeout.
    private var lastUtteranceAt: Date?

    /// Sessions the user dismissed via "Not a Meeting" (by detected app bundle ID).
    /// Cleared on app restart. Prevents re-prompting for the same app within a session.
    private(set) var dismissedEvents: Set<String> = []

    /// Retained reference to the active settings for detection callbacks.
    private(set) var activeSettings: AppSettings?

    /// Closure to check if a session is currently active (recording).
    /// Used to suppress detection prompts during active recording.
    var isSessionActive: () -> Bool = { false }

    // MARK: - Init

    init() {
        let (stream, continuation) = AsyncStream<DetectionEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.eventContinuation = continuation
    }

    /// Yield an event into the stream. Visible for testing.
    func yield(_ event: DetectionEvent) {
        eventContinuation.yield(event)
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Setup / Teardown

    /// Initialize and start the meeting detection system.
    func setup(settings: AppSettings) {
        guard meetingDetector == nil else { return }
        activeSettings = settings
        isEnabled = true

        let detector = MeetingDetector(
            customBundleIDs: settings.customMeetingAppBundleIDs
        )
        meetingDetector = detector

        let service = NotificationService()
        notificationService = service

        // Wire notification callbacks to yield events
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

        // Start listening for detection events from the MeetingDetector
        detectionTask = Task { [weak self] in
            await detector.start()

            for await event in detector.events {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                switch event {
                case .detected(let app):
                    await self.handleMeetingDetected(app: app)
                case .ended:
                    self.handleMeetingEnded()
                }
            }
        }

        installSleepObserver()

        if settings.detectionLogEnabled {
            logger.info("Detection system started")
        }
    }

    /// Tear down the meeting detection system.
    func teardown() {
        detectionTask?.cancel()
        detectionTask = nil

        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        isMonitoringSilence = false

        appExitMonitorTask?.cancel()
        appExitMonitorTask = nil

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
        isEnabled = false
        detectedApp = nil
        lastUtteranceAt = nil

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
                if self.activeSettings?.detectionLogEnabled == true {
                    logger.info("System sleep detected, yielding event")
                }
                self.eventContinuation.yield(.systemSleep)
            }
        }
    }

    // MARK: - Silence Monitoring

    /// Start monitoring for silence timeout during an auto-detected session.
    func startSilenceMonitoring() {
        lastUtteranceAt = Date()
        silenceCheckTask?.cancel()
        isMonitoringSilence = true

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
                        self.eventContinuation.yield(.silenceTimeout)
                        break
                    }
                }
            }
        }
    }

    /// Stop silence monitoring (e.g. when session ends).
    func stopSilenceMonitoring() {
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        lastUtteranceAt = nil
        isMonitoringSilence = false
    }

    /// Called when a new utterance arrives, resets the silence timer.
    func noteUtterance() {
        lastUtteranceAt = Date()
    }

    // MARK: - Meeting App Process Monitor

    /// Start polling for meeting app process exit during recording.
    /// When the meeting app that triggered detection is no longer running,
    /// yield `.meetingAppExited` so the coordinator can auto-stop.
    func startAppExitMonitoring(bundleID: String) {
        appExitMonitorTask?.cancel()

        appExitMonitorTask = Task { [weak self] in
            // Poll every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let isRunning = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == bundleID
                }

                if !isRunning {
                    if self.activeSettings?.detectionLogEnabled == true {
                        logger.info("Meeting app exited (\(bundleID, privacy: .public)), yielding event")
                    }
                    self.eventContinuation.yield(.meetingAppExited)
                    break
                }
            }
        }
    }

    /// Stop monitoring for meeting app process exit.
    func stopAppExitMonitoring() {
        appExitMonitorTask?.cancel()
        appExitMonitorTask = nil
    }

    // MARK: - Evaluate Immediate

    /// Check current state immediately (e.g. on app launch) to see if a meeting is already active.
    func evaluateImmediate() async {
        guard !isSessionActive() else { return }
        guard let detector = meetingDetector else { return }

        let (micActive, app) = await detector.queryCurrentState()
        if micActive, app != nil {
            await handleMeetingDetected(app: app)
        }
    }

    // MARK: - Detection Event Handlers

    private func handleMeetingDetected(app: MeetingApp?) async {
        detectedApp = app

        // Don't prompt if already recording
        guard !isSessionActive() else { return }

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

    private func handleMeetingEnded() {
        detectedApp = nil
        eventContinuation.yield(.meetingAppExited)
    }

    private func handleDetectionAccepted() {
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
            self.eventContinuation.yield(.accepted(metadata))
        }
    }

    private func handleDetectionNotAMeeting() {
        Task {
            if let app = await meetingDetector?.detectedApp {
                dismissedEvents.insert(app.bundleID)
                eventContinuation.yield(.notAMeeting(bundleID: app.bundleID))
            }
        }

        if activeSettings?.detectionLogEnabled == true {
            logger.debug("User dismissed as not a meeting")
        }
    }

    private func handleDetectionDismissed() {
        eventContinuation.yield(.dismissed)

        if activeSettings?.detectionLogEnabled == true {
            logger.debug("User dismissed notification")
        }
    }

    private func handleDetectionTimeout() {
        eventContinuation.yield(.timeout)

        if activeSettings?.detectionLogEnabled == true {
            logger.debug("Notification timed out")
        }
    }
}
