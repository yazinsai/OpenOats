import AppKit
import OatsCore
import SwiftUI
import UserNotifications

@main
struct OpenOatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(recording: model.recorder != nil)
        }
        .menuBarExtraStyle(.window)
        // Placeholders: the meeting window is #762, Settings and onboarding #763.
        Window("OpenOats", id: AppActions.mainWindowID) {
            MeetingsWindow(model: model)
        }
        Settings {
            Text("Settings").frame(width: 480, height: 320)
        }
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
        Image(systemName: recording ? "record.circle.fill" : "waveform")
            .onAppear {
                AppActions.openMainWindow = { [openWindow] in
                    Dock.show()
                    openWindow(id: AppActions.mainWindowID)
                }
                AppActions.openSettings = { [openSettings] in
                    Dock.show()
                    openSettings()
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Before any `openoats://start`: recovery must not close a Meeting that is being recorded.
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN) // writing keys to a Processing child that already exited
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    /// A Meeting file notification opens the file; the others open the window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let file = response.notification.request.content.userInfo["file"] as? String
        await MainActor.run {
            if let file { NSWorkspace.shared.open(URL(fileURLWithPath: file)) } else { AppActions.openMainWindow() }
        }
    }
}

enum Notifier {
    static func post(_ title: String, _ body: String = "", file: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return print("\(title): \(body)") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file { content.userInfo = ["file": file] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
