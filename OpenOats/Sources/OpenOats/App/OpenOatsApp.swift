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
        Window("OpenOats", id: "main") {
            ContentView(settings: settings)
                .environment(coordinator)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    settings.applyScreenShareVisibility()
                }
                .onOpenURL { url in
                    guard let command = OpenOatsDeepLink.parse(url) else { return }
                    coordinator.queueExternalCommand(command)
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

                Button("GitHub Repository...") {
                    if let url = URL(string: "https://github.com/yazinsai/OpenOats") {
                        NSWorkspace.shared.open(url)
                    }
                }
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
    var coordinator: AppCoordinator?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let coordinator else { return nil }
        let menu = NSMenu()
        if coordinator.isRecording {
            let item = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func startRecording() {
        coordinator?.queueExternalCommand(.startSession)
    }

    @objc private func stopRecording() {
        coordinator?.queueExternalCommand(.stopSession)
    }

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
