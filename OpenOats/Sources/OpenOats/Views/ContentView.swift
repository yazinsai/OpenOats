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
                Text(String(localized: "openoats"))
                    .font(.subheadline)

                Spacer()

                // KB indexing status (subtle, read-only)
                if !controllerState.kbIndexingProgress.isEmpty {
                    Text(controllerState.kbIndexingProgress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    openWindow(id: "notes")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.caption)
                        Text(String(localized: "past_meetings"))
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "view_past_meeting_notes"))
                .accessibilityIdentifier("app.pastMeetingsButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Post-session banner
            if let lastSession = controllerState.lastEndedSession, lastSession.utteranceCount > 0 {
                HStack {
                    Text(String(localized: "session_ended_u00b7_lastsessionutterancecount_utte"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("app.sessionEndedBanner")
                    Spacer()
                    if controllerState.lastSessionHasNotes {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label(String(localized: "view_notes"), systemImage: "doc.text")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("app.viewNotesButton")
                    } else {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label(String(localized: "generate_notes"), systemImage: "sparkles")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("app.generateNotesButton")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
            }

            // Batch transcription / import progress banner
            if case .transcribing(let progress) = controllerState.batchStatus {
                HStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(controllerState.batchIsImporting
                         ? "Importing meeting recording… \(Int(progress * 100))%"
                         : "Enhancing transcript... \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                Divider()
            } else if case .loading = controllerState.batchStatus {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controllerState.batchIsImporting
                         ? "Preparing to import…"
                         : "Loading batch model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                Divider()
            } else if case .completed = controllerState.batchStatus {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                    Text(controllerState.batchIsImporting
                         ? "Meeting recording imported"
                         : "Transcript enhanced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                Divider()
            }

            // Main content: Suggestions
            VStack(alignment: .leading, spacing: 0) {
                Text("SUGGESTIONS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                SuggestionsView(
                    suggestions: controllerState.suggestions,
                    isGenerating: controllerState.isGeneratingSuggestions
                )
            }

            Divider()

            // Collapsible transcript (hidden when live transcript is disabled)
            if controllerState.showLiveTranscript {
                DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                    TranscriptView(
                        utterances: controllerState.liveTranscript,
                        volatileYouText: controllerState.volatileYouText,
                        volatileThemText: controllerState.volatileThemText
                    )
                    .frame(height: 150)
                } label: {
                    HStack(spacing: 6) {
                        Text(String(localized: "transcript"))
                            .font(.footnote)
                        if !controllerState.liveTranscript.isEmpty {
                            Text(String(localized: "controllerstatelivetranscriptcount"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isTranscriptExpanded && !controllerState.liveTranscript.isEmpty {
                            Button {
                                openWindow(id: "transcript")
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "open_transcript_in_separate_window"))

                            Button {
                                copyTranscript()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "copy_transcript"))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            // Bottom bar: live indicator + model
            ControlBar(
                isRunning: controllerState.isRunning,
                audioLevel: controllerState.audioLevel,
                isMicMuted: controllerState.isMicMuted,
                modelDisplayName: controllerState.modelDisplayName,
                transcriptionPrompt: controllerState.transcriptionPrompt,
                statusMessage: controllerState.statusMessage,
                errorMessage: controllerState.errorMessage,
                needsDownload: controllerState.needsDownload,
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
                OnboardingView(isPresented: $showOnboarding)
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
            controller.onRunningStateChanged = { [weak miniBarManager] isRunning in
                if isRunning {
                    miniBarManager?.state.onTap = {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    showMiniBar(controller: controller, miniBarManager: miniBarManager)
                } else {
                    miniBarManager?.hide()
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
            controller.indexKBIfNeeded(settings: settings)
            controller.handlePendingExternalCommandIfPossible(settings: settings) {
                openWindow(id: "notes")
            }

            await controller.performInitialSetup()

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
    }

    private var contentWithEventHandlers: some View {
        contentWithLifecycle
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
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
        guard let controller = liveSessionController else { return }
        let content = OverlayContent(
            suggestions: controller.state.suggestions,
            isGenerating: controller.state.isGeneratingSuggestions,
            volatileThemText: controller.state.volatileThemText
        )
        overlayManager.toggle(content: content)
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
            } else {
                startSession()
            }
        case .confirmDownload:
            guard settings.hasAcknowledgedRecordingConsent else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showConsentSheet = true
                }
                return
            }
            liveSessionController?.confirmDownloadAndStart(settings: settings)
        }
    }
}
