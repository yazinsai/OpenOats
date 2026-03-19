import SwiftUI
import Combine

struct ContentView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var transcriptStore = TranscriptStore()
    @State private var knowledgeBase: KnowledgeBase?
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var suggestionEngine: SuggestionEngine?
    @State private var transcriptLogger: TranscriptLogger?
    @State private var overlayManager = OverlayManager()
    @AppStorage("isTranscriptExpanded") private var isTranscriptExpanded = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false
    @State private var audioLevel: Float = 0

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            topBar

            Divider()

            // Post-session banner
            if let lastSession = coordinator.lastEndedSession, lastSession.utteranceCount > 0 {
                HStack {
                    Text("Session ended \u{00B7} \(lastSession.utteranceCount) utterances")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if lastSessionHasNotes {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label("View Notes", systemImage: "doc.text")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label("Generate Notes", systemImage: "sparkles")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
            }

            // Main content: Suggestions
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("SUGGESTIONS")
                SuggestionsView(
                    suggestions: suggestionEngine?.suggestions ?? [],
                    isGenerating: suggestionEngine?.isGenerating ?? false
                )
            }

            Divider()

            // Collapsible transcript
            DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                TranscriptView(
                    utterances: transcriptStore.utterances,
                    volatileYouText: transcriptStore.volatileYouText,
                    volatileThemText: transcriptStore.volatileThemText
                )
                .frame(height: 150)
            } label: {
                HStack(spacing: 6) {
                    Text("Transcript")
                        .font(.system(size: 12, weight: .medium))
                    if !transcriptStore.utterances.isEmpty {
                        Text("(\(transcriptStore.utterances.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if isTranscriptExpanded && !transcriptStore.utterances.isEmpty {
                        Button {
                            copyTranscript()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy transcript")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Bottom bar: live indicator + model
            ControlBar(
                isRunning: isRunning,
                audioLevel: audioLevel,
                modelDisplayName: settings.activeModelDisplay,
                transcriptionPrompt: settings.transcriptionModel.downloadPrompt,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                needsDownload: transcriptionEngine?.needsModelDownload ?? false,
                onToggle: isRunning ? stopSession : startSession,
                onConfirmDownload: confirmDownloadAndStart
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
        .onChange(of: showOnboarding) {
            if !showOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: showConsentSheet) {
            // Auto-start session after consent is acknowledged
            if !showConsentSheet && settings.hasAcknowledgedRecordingConsent && !isRunning {
                startSession()
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if knowledgeBase == nil {
                let kb = KnowledgeBase(settings: settings)
                knowledgeBase = kb
                transcriptionEngine = TranscriptionEngine(
                    transcriptStore: transcriptStore,
                    settings: settings
                )
                suggestionEngine = SuggestionEngine(
                    transcriptStore: transcriptStore,
                    knowledgeBase: kb,
                    settings: settings
                )
                transcriptLogger = TranscriptLogger(
                    directory: URL(fileURLWithPath: settings.notesFolderPath)
                )
            }
            indexKBIfNeeded()
        }
        .onChange(of: settings.kbFolderPath) {
            if settings.kbFolderPath.isEmpty {
                knowledgeBase?.clear()
            } else {
                indexKBIfNeeded()
            }
        }
        .onChange(of: settings.notesFolderPath) {
            Task {
                await transcriptLogger?.updateDirectory(
                    URL(fileURLWithPath: settings.notesFolderPath)
                )
            }
        }
        .onChange(of: settings.voyageApiKey) {
            indexKBIfNeeded()
        }
        .onChange(of: settings.transcriptionModel) {
            transcriptionEngine?.refreshModelAvailability()
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard let engine = transcriptionEngine else {
                if audioLevel != 0 { audioLevel = 0 }
                return
            }
            if engine.isRunning {
                audioLevel = engine.audioLevel
            } else if audioLevel != 0 {
                audioLevel = 0
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Text("OpenOats")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // KB indexing status (subtle, read-only)
            if let kb = knowledgeBase, !kb.indexingProgress.isEmpty {
                Text(kb.indexingProgress)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                openWindow(id: "notes")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text("Past Meetings")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    /// Check if the last ended session already has notes generated.
    private var lastSessionHasNotes: Bool {
        guard let lastSession = coordinator.lastEndedSession else { return false }
        return coordinator.sessionHistory.first { $0.id == lastSession.id }?.hasNotes ?? false
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .tracking(1.5)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func confirmDownloadAndStart() {
        transcriptionEngine?.downloadConfirmed = true
        startSession()
    }

    private func startSession() {
        // Gate recording behind consent acknowledgment
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }

        Task {
            suggestionEngine?.clear()
            await coordinator.startSession(transcriptStore: transcriptStore)
            await transcriptLogger?.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                transcriptionModel: settings.transcriptionModel
            )
        }
    }

    private func stopSession() {
        Task {
            await coordinator.finalizeSession(
                transcriptStore: transcriptStore,
                transcriptionEngine: transcriptionEngine,
                transcriptLogger: transcriptLogger
            )
        }
    }

    private func toggleOverlay() {
        let content = OverlayContent(
            suggestions: suggestionEngine?.suggestions ?? [],
            isGenerating: suggestionEngine?.isGenerating ?? false,
            volatileThemText: transcriptStore.volatileThemText
        )
        overlayManager.toggle(content: content)
    }

    private func indexKBIfNeeded() {
        guard let url = settings.kbFolderURL, let kb = knowledgeBase else { return }
        Task {
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = transcriptStore.utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handleNewUtterance() {
        let utterances = transcriptStore.utterances
        guard let last = utterances.last else { return }

        // Persist to transcript log
        Task {
            await transcriptLogger?.append(
                speaker: last.speaker == .you ? "You" : "Them",
                text: last.text,
                timestamp: last.timestamp
            )
        }

        // Trigger suggestions on THEM utterance
        if last.speaker == .them {
            suggestionEngine?.onThemUtterance(last)

            // Delayed write owned by SessionStore (tracks pending writes for drain)
            let baseRecord = SessionRecord(
                speaker: last.speaker,
                text: last.text,
                timestamp: last.timestamp
            )
            Task {
                await coordinator.sessionStore.appendRecordDelayed(
                    baseRecord: baseRecord,
                    suggestionEngine: suggestionEngine,
                    transcriptStore: transcriptStore
                )
            }
        } else {
            // Log non-them utterances immediately
            Task {
                await coordinator.sessionStore.appendRecord(SessionRecord(
                    speaker: last.speaker,
                    text: last.text,
                    timestamp: last.timestamp
                ))
            }
        }
    }
}
