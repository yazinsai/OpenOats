import AppKit
import SwiftUI

struct ContentView: View {
    private enum ControlBarAction {
        case toggle
        case confirmDownload
    }

    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var overlayManager = OverlayManager()
    @State private var miniBarManager = MiniBarManager()
    @State private var liveSessionController: LiveSessionController?
    @AppStorage("isTranscriptExpanded") private var isTranscriptExpanded = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false
    @State private var pendingControlBarAction: ControlBarAction?

    var body: some View {
        bodyWithModifiers
    }

    private var rootContent: some View {
        let controllerState = liveSessionController?.state ?? LiveSessionState()

        return VStack(spacing: 0) {
            // Compact header
            HStack {
                Text("OpenOats")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    openWindow(id: "notes")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                        Text("Past Meetings")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("View past meeting notes")
                .accessibilityIdentifier("app.pastMeetingsButton")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityIdentifier("app.settingsButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Post-session banner
            if let lastSession = controllerState.lastEndedSession, lastSession.utteranceCount > 0 {
                HStack {
                    Text("Session ended \u{00B7} \(lastSession.utteranceCount) utterances")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("app.sessionEndedBanner")
                    Spacer()
                    if controllerState.lastSessionHasNotes {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label("View Notes", systemImage: "doc.text")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("app.viewNotesButton")
                    } else {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label("Generate Notes", systemImage: "sparkles")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(OpenOatsProminentButtonStyle())
                        .controlSize(.small)
                        .accessibilityIdentifier("app.generateNotesButton")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
            }

            if controllerState.isRunning, let event = controllerState.matchedCalendarEvent {
                MatchedCalendarEventBanner(event: event)

                Divider()
            }

            // Suggestion panel status
            if controllerState.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controllerState.isGeneratingSuggestions ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(settings.sidebarMode == .sidecast ? "Sidecast" : "Suggestions") \(overlayManager.isVisible ? "visible" : "hidden")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        toggleOverlay()
                    } label: {
                        Text(overlayManager.isVisible ? "Hide Panel" : "Show Panel")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            if controllerState.isRunning {
                Spacer(minLength: 0)

                // Collapsible transcript (hidden when live transcript is disabled)
                if controllerState.showLiveTranscript {
                    DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                        IsolatedTranscriptWrapper(state: controllerState)
                            .frame(height: 150)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Transcript")
                                .font(.system(size: 12, weight: .medium))
                            if !controllerState.liveTranscript.isEmpty {
                                Text("(\(controllerState.liveTranscript.count))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if isTranscriptExpanded && !controllerState.liveTranscript.isEmpty {
                                Button {
                                    openWindow(id: "transcript")
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(4)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help("Open transcript in separate window")

                                Button {
                                    copyTranscript()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(4)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help("Copy transcript")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                Divider()
                ScratchpadSection(
                    text: Binding(
                        get: { controllerState.scratchpadText },
                        set: { liveSessionController?.updateScratchpad($0) }
                    )
                )
            } else {
                IdleHomeDashboardView(settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            // Bottom bar: live indicator + model
            IsolatedControlBarWrapper(
                state: controllerState,
                onToggle: {
                    pendingControlBarAction = .toggle
                },
                onMuteToggle: {
                    liveSessionController?.toggleMicMute()
                },
                onConfirmDownload: {
                    pendingControlBarAction = .confirmDownload
                }
            )
        }
    }

    private var bodyWithModifiers: some View {
        contentWithEventHandlers
    }

    private var sizedRootContent: some View {
        rootContent
            .frame(minWidth: 360, maxWidth: 600, minHeight: 400)
            .background(.ultraThinMaterial)
    }

    private var contentWithOverlay: some View {
        sizedRootContent.overlay {
            if showOnboarding {
                SetupWizardView(
                    isPresented: $showOnboarding,
                    settings: settings
                )
                    .transition(.opacity)
            }
            if showConsentSheet {
                RecordingConsentView(
                    isPresented: $showConsentSheet,
                    settings: settings
                )
                .transition(.opacity)
            }
        }
    }

    private var contentWithLifecycle: some View {
        contentWithOverlay
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: showConsentSheet) { _, isShowing in
            if !isShowing && settings.hasAcknowledgedRecordingConsent
                && !(liveSessionController?.state.isRunning ?? false) {
                liveSessionController?.startSession(settings: settings)
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if coordinator.knowledgeBase == nil {
                container.ensureServicesInitialized(settings: settings, coordinator: coordinator)
            }

            // Create and wire the controller
            let controller = LiveSessionController(coordinator: coordinator, container: container)
            controller.onRunningStateChanged = { [weak miniBarManager, weak overlayManager] isRunning in
                if isRunning {
                    miniBarManager?.state.onTap = {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    showMiniBar(controller: controller, miniBarManager: miniBarManager)
                    // Start the selected realtime sidebar and show the overlay.
                    if settings.sidebarMode == .classicSuggestions {
                        coordinator.suggestionEngine?.startPreFetching()
                    }
                    if settings.suggestionPanelEnabled {
                        showSidebarContent()
                    }
                } else {
                    miniBarManager?.hide()
                    // Stop the classic pre-fetcher and hide the panel after delay.
                    coordinator.suggestionEngine?.stopPreFetching()
                    overlayManager?.hideAfterDelay(seconds: 2)
                }
            }
            controller.openNotesWindow = {
                openWindow(id: "notes")
            }
            controller.onMiniBarContentUpdate = { [weak controller, weak miniBarManager] in
                showMiniBar(controller: controller, miniBarManager: miniBarManager)
            }
            coordinator.liveSessionController = controller
            liveSessionController = controller

            overlayManager.defaults = container.defaults
            miniBarManager.defaults = container.defaults
            await container.seedIfNeeded(coordinator: coordinator)
            controller.handlePendingExternalCommandIfPossible(settings: settings) {
                openWindow(id: "notes")
            }

            await controller.performInitialSetup()

            // Setup calendar integration if enabled
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)

            // Setup meeting detection if enabled
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                await container.detectionController?.evaluateImmediate()
            }

            // Start the 100ms polling loop (runs until task cancelled)
            await controller.runPollingLoop(settings: settings)
        }
        .onChange(of: settings.meetingAutoDetectEnabled) {
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                Task {
                    await container.detectionController?.evaluateImmediate()
                }
            } else {
                container.disableDetection(coordinator: coordinator)
            }
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
        .onChange(of: settings.suggestionsAlwaysOnTop) {
            overlayManager.updateAlwaysOnTop(settings.suggestionsAlwaysOnTop)
        }
        .onChange(of: settings.sidebarMode) {
            if settings.sidebarMode == .classicSuggestions {
                coordinator.suggestionEngine?.startPreFetching()
            } else {
                coordinator.suggestionEngine?.stopPreFetching()
            }
            guard liveSessionController?.state.isRunning == true, settings.suggestionPanelEnabled else { return }
            showSidebarContent()
        }
    }

    private var contentWithEventHandlers: some View {
        contentWithLifecycle
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSuggestionPanel)) { _ in
            toggleOverlay()
        }
        .onChange(of: pendingControlBarAction) {
            guard let action = pendingControlBarAction else { return }
            pendingControlBarAction = nil
            handleControlBarAction(action)
        }
    }

    // MARK: - Actions

    private func startSession() {
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }
        liveSessionController?.startSession(settings: settings)
    }

    private func stopSession() {
        liveSessionController?.stopSession(settings: settings)
    }

    private func showMiniBar(controller: LiveSessionController?, miniBarManager: MiniBarManager?) {
        guard let controller, let miniBarManager else { return }
        miniBarManager.update(
            audioLevel: controller.state.audioLevel,
            suggestions: controller.state.suggestions,
            isGenerating: controller.state.isGeneratingSuggestions
        )
        miniBarManager.show()
    }

    private func toggleOverlay() {
        switch settings.sidebarMode {
        case .classicSuggestions:
            overlayManager.toggle(content: SuggestionPanelContent(engine: coordinator.suggestionEngine))
        case .sidecast:
            overlayManager.toggleSidecast(content: sidecastContent())
        }
    }

    private func showSidebarContent() {
        switch settings.sidebarMode {
        case .classicSuggestions:
            overlayManager.showSidePanel(content: SuggestionPanelContent(engine: coordinator.suggestionEngine))
        case .sidecast:
            overlayManager.showSidecastSidebar(content: sidecastContent())
        }
    }

    private func sidecastContent() -> SidecastPanelContent {
        SidecastPanelContent(settings: settings, engine: coordinator.sidecastEngine)
    }

    private func copyTranscript() {
        guard let controller = liveSessionController else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = controller.state.liveTranscript.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @MainActor
    private func handleControlBarAction(_ action: ControlBarAction) {
        switch action {
        case .toggle:
            if liveSessionController?.state.isRunning ?? false {
                stopSession()
            } else if liveSessionController?.state.downloadProgress == nil {
                startSession()
            }
        case .confirmDownload:
            liveSessionController?.downloadModelOnly(settings: settings)
        }
    }
}

// MARK: - Scratchpad Section

private struct ScratchpadSection: View {
    @Binding var text: String
    @AppStorage("isScratchpadExpanded") private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 6) {
                Text("My Notes")
                    .font(.system(size: 12, weight: .medium))
                if !text.isEmpty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Isolated View Wrappers

private struct IsolatedTranscriptWrapper: View {
    let state: LiveSessionState
    
    var body: some View {
        TranscriptView(
            utterances: state.liveTranscript,
            volatileYouText: state.volatileYouText,
            volatileThemText: state.volatileThemText
        )
    }
}

private struct IsolatedControlBarWrapper: View {
    let state: LiveSessionState
    let onToggle: () -> Void
    let onMuteToggle: () -> Void
    let onConfirmDownload: () -> Void
    
    var body: some View {
        ControlBar(
            isRunning: state.isRunning,
            audioLevel: state.audioLevel,
            isMicMuted: state.isMicMuted,
            modelDisplayName: state.modelDisplayName,
            transcriptionPrompt: state.transcriptionPrompt,
            batchStatus: state.batchStatus,
            batchIsImporting: state.batchIsImporting,
            kbIndexingStatus: state.kbIndexingStatus,
            statusMessage: state.statusMessage,
            errorMessage: state.errorMessage,
            needsDownload: state.needsDownload,
            downloadProgress: state.downloadProgress,
            downloadDetail: state.downloadDetail,
            onToggle: onToggle,
            onMuteToggle: onMuteToggle,
            onConfirmDownload: onConfirmDownload
        )
    }
}
