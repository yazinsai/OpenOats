import SwiftUI
import AppKit
import Sparkle

public struct OpenOatsRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @State private var runtime: AppRuntime
    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults

    public init() {
        let context = AppRuntime.bootstrap()
        self._settings = State(initialValue: context.settings)
        self._coordinator = State(initialValue: context.coordinator)
        self._runtime = State(initialValue: context.runtime)
        self.updaterController = context.updaterController
        self.defaults = context.runtime.defaults
    }

    public var body: some Scene {
        Window("OpenOats", id: "main") {
            ContentView(settings: settings)
                .environment(runtime)
                .environment(coordinator)
                .defaultAppStorage(defaults)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    appDelegate.defaults = defaults
                    settings.applyScreenShareVisibility()
                }
                .onOpenURL { url in
                    guard let command = OpenOatsDeepLink.parse(url) else { return }
                    switch command {
                    case .openNotes(let sessionID):
                        coordinator.queueSessionSelection(sessionID)
                        openNotesWindow()
                    default:
                        coordinator.queueExternalCommand(command)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                if case .live = runtime.mode {
                    CheckForUpdatesView(updater: updaterController.updater)

                    Divider()
                }

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
                .environment(runtime)
                .environment(coordinator)
                .defaultAppStorage(defaults)
        }
        .defaultSize(width: 700, height: 550)

        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
                .environment(runtime)
                .environment(coordinator)
                .defaultAppStorage(defaults)
        }
    }
}

extension OpenOatsRootApp {
    private func openNotesWindow() {
        openWindow(id: "notes")
    }
}

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?
    var coordinator: AppCoordinator?
    var defaults: UserDefaults = .standard

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
        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
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
                let hide = self.defaults.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : self.defaults.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                }
            }
        }
    }
}
