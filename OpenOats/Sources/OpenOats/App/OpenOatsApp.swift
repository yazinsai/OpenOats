import SwiftUI
import AppKit
import AVFoundation
import Sparkle
import UniformTypeIdentifiers
import UserNotifications

public struct OpenOatsRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @State private var container: AppContainer
    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults

    public init() {
        let context = AppContainer.bootstrap()
        self._settings = State(initialValue: context.settings)
        self._coordinator = State(initialValue: context.coordinator)
        self._container = State(initialValue: context.container)
        self.updaterController = context.updaterController
        self.defaults = context.container.defaults
        DiagnosticsSupport.record(category: "app", message: "App initialized")
    }

    public var body: some Scene {
        Window("OpenOats", id: "main") {
            ContentView(settings: settings)
                .environment(container)
                .environment(coordinator)
                .defaultAppStorage(defaults)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    appDelegate.settings = settings
                    appDelegate.defaults = defaults
                    appDelegate.container = container
                    DiagnosticsSupport.record(category: "app", message: "Main window appeared")
                    if case .live = container.mode {
                        appDelegate.setupMenuBarIfNeeded(
                            coordinator: coordinator,
                            settings: settings,
                            showMainWindow: { [self] in showMainWindow() },
                            checkForUpdates: { updaterController.checkForUpdatesFromMenuBar() }
                        )
                    }
                    settings.applyScreenShareVisibility()
                }
                .onOpenURL { url in
                    guard let command = OpenOatsDeepLink.parse(url) else { return }
                    // Restore visibility when app is in background mode (LSUIElement)
                    if NSApp.activationPolicy() == .accessory {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
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

                Button("Import Meeting Recording...") {
                    importMeetingRecording()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(coordinator.isRecording || isBatchEngineBusy)

                Button("GitHub Repository...") {
                    if let url = URL(string: "https://github.com/yazinsai/OpenOats") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("Notes", id: "notes") {
            NotesView(settings: settings)
                .environment(container)
                .environment(coordinator)
                .defaultAppStorage(defaults)
        }
        .defaultSize(width: 700, height: 550)

        Window("Transcript", id: "transcript") {
            TranscriptWindowView()
                .environment(container)
                .environment(coordinator)
                .environment(coordinator.transcriptStore)
                .defaultAppStorage(defaults)
        }
        .defaultSize(width: 600, height: 700)

        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
                .environment(container)
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

    private var isBatchEngineBusy: Bool {
        switch coordinator.batchStatus {
        case .idle, .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    private func importMeetingRecording() {
        let panel = NSOpenPanel()
        panel.title = "Import Meeting Recording"
        panel.allowedContentTypes = [
            .audio,
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "caf")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
        guard let batchAudioTranscriber = coordinator.batchAudioTranscriber else { return }

        let model = settings.transcriptionModel
        let locale = settings.locale
        let repo = coordinator.sessionRepository

        // Derive start date and duration from file
        let fm = FileManager.default
        let startDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let creation = attrs[.creationDate] as? Date {
            startDate = creation
        } else {
            startDate = Date()
        }

        // Estimate duration from audio file for endedAt
        var estimatedEnd = startDate
        if let audioFile = try? AVAudioFile(forReading: fileURL) {
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            estimatedEnd = startDate.addingTimeInterval(duration)
        }

        let title = fileURL.deletingPathExtension().lastPathComponent

        Task {
            let sessionID = await repo.createImportedSession(
                config: .init(
                    title: title,
                    startedAt: startDate,
                    endedAt: estimatedEnd,
                    language: settings.transcriptionLocale,
                    engine: model.rawValue
                )
            )

            await batchAudioTranscriber.importFile(
                url: fileURL,
                sessionID: sessionID,
                model: model,
                locale: locale,
                sessionRepository: repo
            )

            // Check result
            let status = await batchAudioTranscriber.status
            if case .completed = status {
                coordinator.queueSessionSelection(sessionID)
                openNotesWindow()
                await coordinator.loadHistory()
            } else if case .failed = status {
                // Clean up the orphaned session
                await repo.deleteSession(sessionID: sessionID)
                await coordinator.loadHistory()
            } else if case .cancelled = status {
                await repo.deleteSession(sessionID: sessionID)
                await coordinator.loadHistory()
            }
        }
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

extension Notification.Name {
    static let toggleSuggestionPanel = Notification.Name("toggleSuggestionPanel")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windowObserver: Any?
    private var menuBarController: MenuBarController?
    private var isTerminating = false
    var coordinator: AppCoordinator?
    var settings: AppSettings?
    var container: AppContainer?
    var defaults: UserDefaults = .standard

    func setupMenuBarIfNeeded(
        coordinator: AppCoordinator,
        settings: AppSettings,
        showMainWindow: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        guard menuBarController == nil else { return }

        let controller = MenuBarController(
            coordinator: coordinator,
            settings: settings,
            onCheckForUpdates: checkForUpdates,
            onToggleMeeting: { [weak self] in
                self?.toggleMeeting()
            }
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

    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

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
        isUITest
    }

    // MARK: - NSWindowDelegate

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

    // MARK: - One-Shot Background Notification

    private func showBackgroundModeHintIfNeeded() {
        guard !defaults.bool(forKey: "hasShownBackgroundModeHint") else { return }
        guard settings?.meetingAutoDetectEnabled == true else { return }
        // UNUserNotificationCenter asserts when there's no bundle identifier
        // (e.g. when built and run via `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }

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

    // MARK: - Global Hotkey (Cmd+Shift+L)

    private func registerGlobalHotkey() {
        let matchesMeetingHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains([.command, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == "l"
        }

        let matchesPanelHotkey: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains([.command, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == "o"
        }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if matchesMeetingHotkey(event) {
                Task { @MainActor in self?.toggleMeeting() }
            } else if matchesPanelHotkey(event) {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .toggleSuggestionPanel, object: nil)
                }
            }
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if matchesMeetingHotkey(event) {
                Task { @MainActor in self?.toggleMeeting() }
                return nil
            } else if matchesPanelHotkey(event) {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .toggleSuggestionPanel, object: nil)
                }
                return nil
            }
            return event
        }
    }

    func toggleMeeting() {
        guard let coordinator, let settings else { return }
        guard settings.hasAcknowledgedRecordingConsent else { return }

        container?.ensureMeetingServicesInitialized(settings: settings, coordinator: coordinator)

        if coordinator.isRecording {
            coordinator.handle(.userStopped, settings: settings)
        } else {
            let calEvent = settings.calendarIntegrationEnabled
                ? container?.calendarManager?.currentEvent()
                : nil
            coordinator.handle(.userStarted(.manual(calendarEvent: calEvent)), settings: settings)
        }
    }

    // MARK: - Quit

    private func handleQuit() {
        NSApp.terminate(nil)
    }
}
