import Foundation
import UserNotifications

/// Manages macOS notification delivery for meeting detection prompts.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var hasRequestedPermission = false
    private var pendingTimeoutTask: Task<Void, Never>?

    /// Called when the user taps "Start Transcribing".
    var onAccept: (() -> Void)?

    /// Called when the user taps "Not a Meeting".
    var onNotAMeeting: (() -> Void)?

    /// Called when the user taps "Dismiss".
    var onDismiss: (() -> Void)?

    /// Called when the user taps "Ignore This App".
    var onIgnoreApp: (() -> Void)?

    /// Called when the notification times out (60 seconds).
    var onTimeout: (() -> Void)?

    // MARK: - Action Identifiers

    private static let categoryID = "MEETING_DETECTED"
    private static let startAction = "START_TRANSCRIBING"
    private static let notMeetingAction = "NOT_A_MEETING"
    private static let ignoreAppAction = "IGNORE_APP"
    private static let dismissAction = "DISMISS"

    override init() {
        super.init()
        registerCategory()
    }

    // MARK: - Category Registration

    private func registerCategory() {
        // "Start Transcribing" is the default action (tap on notification body).
        // Only secondary actions appear in the dropdown.
        let notMeeting = UNNotificationAction(
            identifier: Self.notMeetingAction,
            title: "Not a Meeting",
            options: []
        )
        let ignoreApp = UNNotificationAction(
            identifier: Self.ignoreAppAction,
            title: "Ignore This App",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: Self.dismissAction,
            title: "Dismiss",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [notMeeting, ignoreApp, dismiss],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    private func ensurePermission() async -> Bool {
        if hasRequestedPermission {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
        }

        hasRequestedPermission = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return granted
        } catch {
            return false
        }
    }

    // MARK: - Notification Delivery

    /// Post a meeting detection notification with the given app name.
    /// Returns false if permission was denied.
    func postMeetingDetected(appName: String?) async -> Bool {
        guard await ensurePermission() else { return false }

        // Cancel any existing timeout
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil

        // Remove previous detection notifications
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["meeting-detection"]
        )

        let content = UNMutableNotificationContent()
        if let appName {
            content.title = "Meeting Detected"
            content.body = "\(appName) is using your microphone. Tap to start transcribing."
        } else {
            content.title = "Microphone Active"
            content.body = "A meeting may be in progress. Tap to start transcribing."
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let request = UNNotificationRequest(
            identifier: "meeting-detection",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return false
        }

        // Start 60-second timeout
        pendingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            Task { @MainActor [weak self] in
                self?.onTimeout?()
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["meeting-detection"]
            )
        }

        return true
    }

    /// Post a notification when batch transcription completes.
    func postBatchCompleted(sessionID: String) async {
        guard await ensurePermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Re-transcription Complete"
        content.body = "Batch transcription is complete. Your meeting transcript has been updated with higher-quality text."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "batch-completed-\(sessionID)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Remove any pending detection notification.
    func cancelPending() {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["meeting-detection"]
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionID = response.actionIdentifier

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.pendingTimeoutTask?.cancel()
            self.pendingTimeoutTask = nil

            switch actionID {
            case Self.startAction:
                self.onAccept?()
            case Self.notMeetingAction:
                self.onNotAMeeting?()
            case Self.ignoreAppAction:
                self.onIgnoreApp?()
            case Self.dismissAction, UNNotificationDismissActionIdentifier:
                self.onDismiss?()
            default:
                // Default action (tap on notification body) -- treat as accept
                self.onAccept?()
            }
        }

        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
