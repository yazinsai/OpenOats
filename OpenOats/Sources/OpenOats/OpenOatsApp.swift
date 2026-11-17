import AppKit
import OatsCore
import SwiftUI
import UserNotifications

@main
struct OpenOatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        // A UI-test copy launched without its isolation (e.g. by LaunchServices) must never reach the real settings or Keychain.
        if Bundle.main.bundleIdentifier == "com.openoats.ui-smoke", ProcessInfo.processInfo.environment["OATS_DEFAULTS_SUITE"] == nil { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(recording: model.recorder != nil)
        }
        .menuBarExtraStyle(.window)
        Window("OpenOats", id: AppActions.mainWindowID) {
            MeetingsWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        Window("Welcome to OpenOats", id: OnboardingView.windowID) { OnboardingView(model: .shared) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        Settings { SettingsView(model: .shared) }
    }
}

/// Window actions captured from SwiftUI, so the hotkey and notification clicks can use them too.
@MainActor
enum AppActions {
    static let mainWindowID = "main"
    static var openMainWindow: () -> Void = {}
    static var openSettings: () -> Void = {}
}

/// The status item icon. Its environment is the first one SwiftUI builds, so it captures the window actions.
struct MenuBarLabel: View {
    let recording: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: Self.icon(recording: recording))
            .accessibilityLabel(recording ? "OpenOats, recording" : "OpenOats")
            .onAppear {
                AppActions.openMainWindow = { [openWindow] in
                    Dock.show()
                    openWindow(id: AppActions.mainWindowID)
                }
                AppActions.openSettings = { [openSettings] in
                    Dock.show()
                    openSettings()
                }
                if !AppModel.shared.onboarded {
                    Dock.show()
                    openWindow(id: OnboardingView.windowID)
                }
            }
    }
}

extension MenuBarLabel {
    /// A template glyph of the logo: two concentric rings. While recording the inner ring fills to a dot,
    /// so the state reads by shape as well as weight.
    static func icon(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            // On the 2x pixel grid: stroke edges land on whole pixels.
            NSColor.black.set()
            let outer = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 1.25, width: 13.5, height: 13.5))
            outer.lineWidth = 1.5
            outer.stroke()
            if recording {
                NSBezierPath(ovalIn: NSRect(x: 5.5, y: 4.5, width: 7, height: 7)).fill()
            } else {
                let inner = NSBezierPath(ovalIn: NSRect(x: 6.25, y: 5.25, width: 5.5, height: 5.5))
                inner.lineWidth = 1.5
                inner.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Before any `openoats://start`: recovery must not close a Meeting that is being recorded.
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN) // writing keys to a Processing child that already exited
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            CallPrompt.register()
        }
        AppModel.shared.launch()
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        Dock.follow()
        HotkeyMonitor.register(Hotkey.saved)
        Updater.shared.start()
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopProcessingChild()
        _ = try? AppModel.shared.recorder?.stop()
    }

    /// Opening the app again (Finder, Spotlight) shows the window.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppActions.openMainWindow()
        return false
    }

    /// `openoats://start` and `openoats://stop`, as in 1.x (Shortcuts, Raycast, scripts).
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "openoats" {
            if url.host == "start" { AppModel.shared.start() } else if url.host == "stop" { AppModel.shared.stop() }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .list] }

    /// A click opens the window, with the notification's Meeting selected. A click on a Call prompt records the Call.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if let call = (response.notification.request.content.userInfo["call"] as? String).flatMap(CallApp.named) {
            let ignore = response.actionIdentifier == CallPrompt.ignoreAction
            return await MainActor.run { ignore ? AppModel.shared.ignore(call) : AppModel.shared.record(call) }
        }
        let meeting = response.notification.request.content.userInfo["meeting"] as? String
        await MainActor.run {
            if let meeting { AppModel.shared.selection = meeting }
            AppActions.openMainWindow()
        }
    }
}

enum Notifier {
    static func post(_ title: String, _ body: String = "", meeting: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return print("\(title): \(body)") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meeting { content.userInfo = ["meeting": meeting] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// The "Record this meeting?" notification, one per Call. Clicking it (or Record) records; it is withdrawn when
/// the Call ends or a recording starts, so a stale prompt can't start one.
enum CallPrompt {
    static let recordAction = "call.record"
    static let ignoreAction = "call.ignore"

    /// A category per Call app, so the second action can name it.
    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(CallApp.known.map { app in
            UNNotificationCategory(identifier: "call.\(app.id)", actions: [
                UNNotificationAction(identifier: recordAction, title: "Record"),
                UNNotificationAction(identifier: ignoreAction, title: "Don't Ask for \(app.name)"),
            ], intentIdentifiers: [])
        }))
    }

    static func post(_ call: CallApp) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Record this meeting?"
        content.body = "\(call.name) is on a call. Click to record it."
        content.categoryIdentifier = "call.\(call.id)"
        content.userInfo = ["call": call.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call.\(call.id)", content: content, trigger: nil))
    }

    static func withdraw(_ calls: [CallApp]) {
        guard Bundle.main.bundleIdentifier != nil, !calls.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: calls.map { "call.\($0.id)" })
    }
}

/// No Dock icon unless a window (meeting window, Settings, updater) is open.
@MainActor
enum Dock {
    static func follow() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { refresh() } }
            }
        }
    }

    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func refresh() {
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
