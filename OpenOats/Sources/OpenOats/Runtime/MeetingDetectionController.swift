import AppKit
import Foundation
import Observation
import os

private let meetingDetectionLogger = Logger(
    subsystem: "com.openoats.app",
    category: "MeetingDetectionController"
)

@Observable
@MainActor
final class MeetingDetectionController {
    struct State: Sendable {
        var isEnabled = false
        var detectedMeetingApp: MeetingApp?
        var pendingPromptAppName: String?
        var silenceTimerStartedAt: Date?
        var lastDismissedBundleID: String?
        var notificationError: String?
    }

    @ObservationIgnored nonisolated(unsafe) private var _state = State()
    var state: State {
        get { access(keyPath: \.state); return _state }
        set { withMutation(keyPath: \.state) { _state = newValue } }
    }

    let settings: SettingsStore
    let liveSessionController: LiveSessionController

    private var meetingDetector: MeetingDetector?
    private var notificationService: NotificationService?
    private var detectionTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var silenceCheckTask: Task<Void, Never>?
    private var sleepObserver: Any?
    private var dismissedEvents: Set<String> = []
    private var lastUtteranceAt: Date?
    private var configuredBundleIDs: [String] = []
    private var didActivate = false

    init(settings: SettingsStore, liveSessionController: LiveSessionController) {
        self.settings = settings
        self.liveSessionController = liveSessionController
    }

    func activateIfNeeded() async {
        guard !didActivate else { return }
        didActivate = true
        synchronizeLifecycle()
        observeSettingsAndSessionState()
    }

    func noteUtterance() {
        lastUtteranceAt = .now
    }

    private func observeSettingsAndSessionState() {
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.synchronizeLifecycle()
                self.synchronizeSilenceMonitoring()

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.settings.meetingAutoDetectEnabled
                        _ = self.settings.customMeetingAppBundleIDs
                        _ = self.settings.silenceTimeoutMinutes
                        _ = self.liveSessionController.state.sessionPhase
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func synchronizeLifecycle() {
        let shouldEnable = settings.meetingAutoDetectEnabled
        let bundleIDs = settings.customMeetingAppBundleIDs

        if shouldEnable && (meetingDetector == nil || bundleIDs != configuredBundleIDs) {
            teardownDetection()
            setupDetection(bundleIDs: bundleIDs)
        } else if !shouldEnable {
            teardownDetection()
        }

        state.isEnabled = shouldEnable
    }

    private func setupDetection(bundleIDs: [String]) {
        configuredBundleIDs = bundleIDs

        let detector = MeetingDetector(customBundleIDs: bundleIDs)
        let service = NotificationService()
        meetingDetector = detector
        notificationService = service

        service.onAccept = { [weak self] in
            guard let self else { return }
            self.handleDetectionAccepted()
        }
        service.onNotAMeeting = { [weak self] in
            guard let self else { return }
            self.handleDetectionNotAMeeting()
        }
        service.onDismiss = { [weak self] in
            guard let self else { return }
            self.state.pendingPromptAppName = nil
        }
        service.onTimeout = { [weak self] in
            guard let self else { return }
            self.state.pendingPromptAppName = nil
        }

        detectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await detector.start()
            for await event in detector.events {
                guard !Task.isCancelled else { break }
                switch event {
                case .detected(let app):
                    await self.handleMeetingDetected(app)
                case .ended:
                    await self.handleMeetingEnded()
                }
            }
        }

        installSleepObserver()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.evaluateImmediate()
        }

        if settings.detectionLogEnabled {
            meetingDetectionLogger.info("Detection system started")
        }
    }

    private func teardownDetection() {
        detectionTask?.cancel()
        detectionTask = nil
        silenceCheckTask?.cancel()
        silenceCheckTask = nil

        Task { [meetingDetector] in
            await meetingDetector?.stop()
        }
        meetingDetector = nil
        notificationService?.cancelPending()
        notificationService = nil

        if let sleepObserver {
            NotificationCenter.default.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }

        state.pendingPromptAppName = nil
        state.detectedMeetingApp = nil
        state.silenceTimerStartedAt = nil
        dismissedEvents.removeAll()
    }

    private func installSleepObserver() {
        sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.liveSessionController.state.hasActiveSession {
                    self.liveSessionController.stopSession()
                }
            }
        }
    }

    private func synchronizeSilenceMonitoring() {
        guard case .recording(let metadata) = liveSessionController.state.sessionPhase,
              case .appLaunched = metadata.detectionContext?.signal else {
            silenceCheckTask?.cancel()
            silenceCheckTask = nil
            state.silenceTimerStartedAt = nil
            return
        }

        guard silenceCheckTask == nil else { return }

        lastUtteranceAt = .now
        state.silenceTimerStartedAt = .now
        silenceCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }

                let timeoutMinutes = self.settings.silenceTimeoutMinutes
                if let lastUtteranceAt = self.lastUtteranceAt,
                   Date().timeIntervalSince(lastUtteranceAt) >= Double(timeoutMinutes) * 60 {
                    if self.settings.detectionLogEnabled {
                        meetingDetectionLogger.info("Silence timeout reached")
                    }
                    self.liveSessionController.stopSession()
                    break
                }
            }
        }
    }

    private func handleMeetingDetected(_ app: MeetingApp?) async {
        guard !liveSessionController.state.hasActiveSession else { return }
        if let bundleID = app?.bundleID, dismissedEvents.contains(bundleID) {
            return
        }

        state.detectedMeetingApp = app
        state.pendingPromptAppName = app?.name

        let posted = await notificationService?.postMeetingDetected(appName: app?.name) ?? false
        if !posted {
            state.notificationError = "Meeting notifications are disabled."
        }
    }

    private func handleMeetingEnded() async {
        state.pendingPromptAppName = nil
        state.detectedMeetingApp = nil

        if case .recording(let metadata) = liveSessionController.state.sessionPhase,
           case .appLaunched = metadata.detectionContext?.signal {
            liveSessionController.stopSession()
        }
    }

    private func handleDetectionAccepted() {
        guard !liveSessionController.state.hasActiveSession else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let app = await self.meetingDetector?.detectedApp
            let context = DetectionContext(
                signal: app.map { .appLaunched($0) } ?? .audioActivity,
                detectedAt: .now,
                meetingApp: app,
                calendarEvent: nil
            )
            let metadata = MeetingMetadata(
                detectionContext: context,
                calendarEvent: nil,
                title: app?.name,
                startedAt: .now,
                endedAt: nil
            )
            self.state.pendingPromptAppName = nil
            self.liveSessionController.startDetectedSession(metadata)
        }
    }

    private func handleDetectionNotAMeeting() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let app = await self.meetingDetector?.detectedApp {
                self.dismissedEvents.insert(app.bundleID)
                self.state.lastDismissedBundleID = app.bundleID
            }
            self.state.pendingPromptAppName = nil
        }
    }

    private func evaluateImmediate() async {
        guard let meetingDetector, !liveSessionController.state.hasActiveSession else { return }
        let (micActive, app) = await meetingDetector.queryCurrentState()
        if micActive, app != nil {
            await handleMeetingDetected(app)
        }
    }
}
