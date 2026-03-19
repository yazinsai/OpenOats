import SwiftUI
import AppKit
import Sparkle

@main
struct OpenOatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings = AppSettings()
    @State private var coordinator = AppCoordinator()
    private let updaterController = AppUpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .environment(coordinator)
                .onAppear {
                    settings.applyScreenShareVisibility()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)

                Divider()

                Button("Past Meetings") {
                    openNotesWindow()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Window("Notes", id: "notes") {
            NotesView(settings: settings)
                .environment(coordinator)
        }
        .defaultSize(width: 700, height: 550)

        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
                .environment(coordinator)
        }
    }
}

extension OpenOatsApp {
    private func openNotesWindow() {
        openWindow(id: "notes")
    }
}

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
        }

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let hide = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                }
            }
        }
    }
}
