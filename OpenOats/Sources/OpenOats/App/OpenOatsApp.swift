import SwiftUI
import AppKit
import Sparkle
import UserNotifications

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
                    appDelegate.settings = settings
                    appDelegate.defaults = defaults
                    appDelegate.runtime = runtime
                    appDelegate.setupMenuBarIfNeeded(
                        coordinator: coordinator,
                        settings: settings,
                        showMainWindow: { [self] in showMainWindow() }
                    )
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
    static let mainWindowID = "main"

    private func openNotesWindow() {
        openWindow(id: "notes")
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.mainWindowID }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Self.mainWindowID)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windowObserver: Any?
    private var menuBarController: MenuBarController?
    private var isTerminating = false
    var coordinator: AppCoordinator?
    var settings: AppSettings?
    var runtime: AppRuntime?
    var defaults: UserDefaults = .standard

    func setupMenuBarIfNeeded(
        coordinator: AppCoordinator,
        settings: AppSettings,
        showMainWindow: @escaping () -> Void
    ) {
        guard menuBarController == nil else { return }

        runtime?.ensureServicesInitialized(settings: settings, coordinator: coordinator)

        let controller = MenuBarController(
            coordinator: coordinator,
            settings: settings
        )
        controller.onShowMainWindow = showMainWindow
        controller.onQuitApp = { [weak self] in
            self?.handleQuit()
        }
        menuBarController = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
            window.delegate = self
        }

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
                    if window.delegate == nil || window.delegate === self {
                        window.delegate = self
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }

        if isTerminating {
            return .terminateNow
        }

        guard coordinator.isRecording else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "Stop recording and quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminating = true
        coordinator.handle(.userStopped, settings: settings)

        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if case .idle = coordinator.state { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.isTerminating = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let isMainWindow = sender.identifier?.rawValue == OpenOatsRootApp.mainWindowID

        if isMainWindow {
            sender.orderOut(nil)
            showBackgroundModeHintIfNeeded()
            return false
        }
        return true
    }

    // MARK: - One-Shot Background Notification

    private func showBackgroundModeHintIfNeeded() {
        guard !defaults.bool(forKey: "hasShownBackgroundModeHint") else { return }
        guard settings?.meetingAutoDetectEnabled == true else { return }

        defaults.set(true, forKey: "hasShownBackgroundModeHint")

        Task {
            let center = UNUserNotificationCenter.current()
            let granted = try? await center.requestAuthorization(options: [.alert])
            guard granted == true else { return }

            let content = UNMutableNotificationContent()
            content.title = "OpenOats is still running"
            content.body = "Meeting detection is active. Click the menu bar icon to access controls."

            let request = UNNotificationRequest(
                identifier: "background-mode-hint",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    // MARK: - Quit

    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
