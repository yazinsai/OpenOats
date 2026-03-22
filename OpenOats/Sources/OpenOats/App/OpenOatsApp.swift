import AppKit
import Sparkle
import SwiftUI
import UserNotifications

public struct OpenOatsRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var container: AppContainer
    @State private var settings: SettingsStore
    @State private var liveSessionController: LiveSessionController
    @State private var meetingDetectionController: MeetingDetectionController
    @State private var notesController: NotesController
    @State private var navigationState: AppNavigationState

    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults

    public init() {
        let bootstrap = AppContainer.bootstrap()
        self._container = State(initialValue: bootstrap.container)
        self._settings = State(initialValue: bootstrap.container.settings)
        self._liveSessionController = State(initialValue: bootstrap.container.liveSessionController)
        self._meetingDetectionController = State(initialValue: bootstrap.container.meetingDetectionController)
        self._notesController = State(initialValue: bootstrap.container.notesController)
        self._navigationState = State(initialValue: bootstrap.container.navigationState)
        self.updaterController = bootstrap.updaterController
        self.defaults = bootstrap.container.defaults
    }

    public var body: some Scene {
        Window("OpenOats", id: Self.mainWindowID) {
            ContentView(settings: settings, defaults: defaults)
                .environment(liveSessionController)
                .environment(meetingDetectionController)
                .environment(notesController)
                .environment(navigationState)
                .defaultAppStorage(defaults)
                .task {
                    await container.activateIfNeeded()
                    handleUITestScenarioIfNeeded()
                }
                .onAppear {
                    appDelegate.liveSessionController = liveSessionController
                    appDelegate.meetingDetectionController = meetingDetectionController
                    appDelegate.settings = settings
                    appDelegate.defaults = defaults

                    if case .live = container.mode {
                        appDelegate.setupMenuBarIfNeeded(
                            liveSessionController: liveSessionController,
                            meetingDetectionController: meetingDetectionController,
                            settings: settings,
                            showMainWindow: { [self] in showMainWindow() },
                            checkForUpdates: { updaterController.checkForUpdatesFromMenuBar() }
                        )
                    }

                    settings.applyScreenShareVisibility()
                }
                .onOpenURL { url in
                    guard let command = OpenOatsDeepLink.parse(url) else { return }
                    if NSApp.activationPolicy() == .accessory {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }

                    switch command {
                    case .startSession:
                        if settings.hasAcknowledgedRecordingConsent {
                            liveSessionController.startManualSession()
                        } else {
                            showMainWindow()
                        }
                    case .stopSession:
                        liveSessionController.stopSession()
                    case .openNotes(let sessionID):
                        navigationState.queueSessionSelection(sessionID)
                        openNotesWindow()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                if case .live = container.mode {
                    CheckForUpdatesView(updater: updaterController.updater)
                    Divider()
                }

                Button("Toggle Meeting") {
                    appDelegate.toggleMeeting()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

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
                .environment(notesController)
                .defaultAppStorage(defaults)
                .task {
                    await container.activateIfNeeded()
                }
        }
        .defaultSize(width: 700, height: 550)

        Window("Transcript", id: "transcript") {
            TranscriptWindowView()
                .environment(liveSessionController)
                .defaultAppStorage(defaults)
                .task {
                    await container.activateIfNeeded()
                }
        }
        .defaultSize(width: 600, height: 700)

        Settings {
            SettingsView(
                settings: settings,
                updater: updaterController.updater,
                templateStore: container.templateStore
            )
            .defaultAppStorage(defaults)
        }
    }
}

extension OpenOatsRootApp {
    static let mainWindowID = "main"

    private func handleUITestScenarioIfNeeded() {
        guard case .uiTest(.notesSmoke) = container.mode else { return }
        navigationState.queueSessionSelection(AppContainer.notesSmokeSessionID)
        openNotesWindow()
    }

    private func openNotesWindow() {
        openWindow(id: "notes")
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
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

    var liveSessionController: LiveSessionController?
    var meetingDetectionController: MeetingDetectionController?
    var settings: SettingsStore?
    var defaults: UserDefaults = .standard

    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    func setupMenuBarIfNeeded(
        liveSessionController: LiveSessionController,
        meetingDetectionController: MeetingDetectionController,
        settings: SettingsStore,
        showMainWindow: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        guard menuBarController == nil else { return }

        let controller = MenuBarController(
            liveSessionController: liveSessionController,
            meetingDetectionController: meetingDetectionController,
            settings: settings,
            onCheckForUpdates: checkForUpdates
        )
        controller.onShowMainWindow = showMainWindow
        controller.onQuitApp = { [weak self] in
            self?.handleQuit()
        }
        menuBarController = controller
    }

    private var isUITest: Bool {
        ProcessInfo.processInfo.environment["OPENOATS_UI_TEST"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isUITest {
            NSApp.setActivationPolicy(.regular)
        }

        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
        }

        if !isUITest {
            for window in NSApp.windows where window.identifier?.rawValue == OpenOatsRootApp.mainWindowID {
                window.delegate = self
            }
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
                }
            }
        }

        registerGlobalHotkey()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let liveSessionController else { return .terminateNow }
        if isTerminating {
            return .terminateNow
        }

        guard liveSessionController.state.isRunning else {
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
        liveSessionController.stopSession()

        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if case .idle = liveSessionController.state.sessionPhase {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.isTerminating = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        isUITest
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isUITest else { return true }

        let isMainWindow = sender.identifier?.rawValue == OpenOatsRootApp.mainWindowID
        if isMainWindow {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            showBackgroundModeHintIfNeeded()
            return false
        }

        return true
    }

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

    private func registerGlobalHotkey() {
        let matchesHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains([.command, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == "l"
        }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matchesHotkey(event) else { return }
            Task { @MainActor in self?.toggleMeeting() }
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard matchesHotkey(event) else { return event }
            Task { @MainActor in self?.toggleMeeting() }
            return nil
        }
    }

    func toggleMeeting() {
        guard let liveSessionController, let settings else { return }
        guard settings.hasAcknowledgedRecordingConsent else { return }

        if liveSessionController.state.isRunning {
            liveSessionController.stopSession()
        } else {
            liveSessionController.startManualSession()
        }
    }

    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
