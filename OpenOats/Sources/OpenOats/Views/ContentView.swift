import SwiftUI

struct ContentView: View {
    private enum ControlBarAction {
        case toggle
        case confirmDownload
    }

    @Bindable var settings: SettingsStore
    let defaults: UserDefaults

    @Environment(LiveSessionController.self) private var liveSessionController
    @Environment(\.openWindow) private var openWindow

    @State private var miniBarManager = MiniBarManager()
    @AppStorage("isTranscriptExpanded") private var isTranscriptExpanded = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false

    var body: some View {
        let state = liveSessionController.state

        VStack(spacing: 0) {
            header(state: state)
            Divider()

            if let lastSession = state.lastEndedSession, lastSession.utteranceCount > 0 {
                sessionBanner(for: lastSession, hasNotes: state.lastSessionHasNotes)
                Divider()
            } else if case .ending = state.sessionPhase, !state.liveTranscript.isEmpty {
                sessionBanner(utteranceCount: state.liveTranscript.count, hasNotes: false)
                Divider()
            }

            batchStatusBanner(state: state)

            VStack(alignment: .leading, spacing: 0) {
                Text("SUGGESTIONS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                SuggestionsView(
                    suggestions: state.suggestions,
                    isGenerating: state.isGeneratingSuggestions
                )
            }

            Divider()

            if state.showLiveTranscript {
                DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                    TranscriptView(
                        utterances: state.liveTranscript,
                        volatileYouText: state.volatileYouText,
                        volatileThemText: state.volatileThemText
                    )
                    .frame(height: 150)
                } label: {
                    transcriptHeader(state: state)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            ControlBar(
                isRunning: state.isRunning,
                isStarting: state.isStartingSession,
                audioLevel: state.audioLevel,
                modelDisplayName: state.modelDisplayName,
                transcriptionPrompt: state.transcriptionPrompt,
                statusMessage: state.statusMessage,
                errorMessage: state.currentError,
                needsDownload: state.needsDownload,
                onToggle: {
                    handleControlBarAction(.toggle)
                },
                onConfirmDownload: {
                    handleControlBarAction(.confirmDownload)
                }
            )
        }
        .frame(minWidth: 360, maxWidth: 600, minHeight: 400)
        .background(.ultraThinMaterial)
        .overlay {
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
        .onAppear {
            miniBarManager.defaults = defaults
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: showConsentSheet) { _, isShowing in
            if !isShowing && settings.hasAcknowledgedRecordingConsent && !liveSessionController.state.hasActiveSession {
                liveSessionController.startManualSession()
            }
        }
        .onChange(of: liveSessionController.state.sessionPhase) { _, _ in
            synchronizeMiniBar()
        }
        .onChange(of: liveSessionController.state.audioLevel) { _, _ in
            synchronizeMiniBar()
        }
        .onChange(of: liveSessionController.state.suggestions.count) { _, _ in
            synchronizeMiniBar()
        }
        .onChange(of: liveSessionController.state.isGeneratingSuggestions) { _, _ in
            synchronizeMiniBar()
        }
    }

    private func header(state: LiveSessionController.State) -> some View {
        HStack {
            Text("OpenOats")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if !state.kbIndexingProgress.isEmpty {
                Text(state.kbIndexingProgress)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sessionBanner(for session: SessionSummary, hasNotes: Bool) -> some View {
        sessionBanner(utteranceCount: session.utteranceCount, hasNotes: hasNotes)
    }

    private func sessionBanner(utteranceCount: Int, hasNotes: Bool) -> some View {
        HStack {
            Text("Session ended · \(utteranceCount) utterances")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("app.sessionEndedBanner")
            Spacer()
            Button {
                openWindow(id: "notes")
            } label: {
                Label(hasNotes ? "View Notes" : "Generate Notes", systemImage: hasNotes ? "doc.text" : "sparkles")
                    .font(.system(size: 12))
            }
            .controlSize(.small)
            .modifier(SessionBannerButtonModifier(isProminent: !hasNotes))
            .accessibilityIdentifier(hasNotes ? "app.viewNotesButton" : "app.generateNotesButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func batchStatusBanner(state: LiveSessionController.State) -> some View {
        switch state.batchStatus {
        case .transcribing(let progress):
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text("Enhancing transcript... \(Int(progress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                Divider()
            }
        case .loading:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading batch model...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                Divider()
            }
        case .completed:
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Transcript enhanced")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                Divider()
            }
        default:
            EmptyView()
        }
    }

    private func transcriptHeader(state: LiveSessionController.State) -> some View {
        HStack(spacing: 6) {
            Text("Transcript")
                .font(.system(size: 12, weight: .medium))
            if !state.liveTranscript.isEmpty {
                Text("(\(state.liveTranscript.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isTranscriptExpanded && !state.liveTranscript.isEmpty {
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

    private func copyTranscript() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = liveSessionController.state.liveTranscript.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker.displayLabel): \(utterance.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func synchronizeMiniBar() {
        let state = liveSessionController.state
        if state.isRunning {
            let content = MiniBarContent(
                audioLevel: state.audioLevel,
                suggestions: state.suggestions,
                isGenerating: state.isGeneratingSuggestions,
                onTap: {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            )
            miniBarManager.show(content: content)
        } else {
            miniBarManager.hide()
        }
    }

    private func handleControlBarAction(_ action: ControlBarAction) {
        switch action {
        case .toggle:
            if liveSessionController.state.isStartingSession {
                return
            } else if liveSessionController.state.isRunning {
                liveSessionController.stopSession()
            } else if settings.hasAcknowledgedRecordingConsent {
                liveSessionController.startManualSession()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showConsentSheet = true
                }
            }
        case .confirmDownload:
            liveSessionController.confirmModelDownloadAndStart()
        }
    }
}

private struct SessionBannerButtonModifier: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
