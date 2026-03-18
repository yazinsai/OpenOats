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
    @State private var transcriptLogger = TranscriptLogger()
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
                    Button {
                        openWindow(id: "notes")
                    } label: {
                        Label("Generate Notes", systemImage: "sparkles")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
                suggestionEngine = SuggestionEngine(
                    transcriptStore: transcriptStore,
                    knowledgeBase: kb,
                    settings: settings
                )
            }
            indexKBIfNeeded()
        }
        .onChange(of: settings.kbFolderPath) {
            indexKBIfNeeded()
        }
        .onChange(of: settings.voyageApiKey) {
            indexKBIfNeeded()
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
        VStack(spacing: 6) {
            // Row 1: App name + KB folder
            HStack {
                Text("OpenOats")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // KB status
                if let kb = knowledgeBase {
                    if !kb.indexingProgress.isEmpty {
                        Text(kb.indexingProgress)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if kb.isIndexed {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                            Text("\(kb.fileCount) files")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                if settings.kbFolderPath.isEmpty {
                    Button("Set KB Folder...") {
                        chooseKBFolder()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentTeal)
                } else {
                    HStack(spacing: 4) {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.kbFolderPath))
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open in Finder")

                        Button("Change...") {
                            chooseKBFolder()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentTeal)
                    }
                }
            }

            // Row 2: Template picker
            HStack {
                @Bindable var coord = coordinator
                Menu {
                    Button {
                        coordinator.selectedTemplate = nil
                    } label: {
                        HStack {
                            Text("None")
                            if coordinator.selectedTemplate == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(coordinator.templateStore.templates) { template in
                        Button {
                            coordinator.selectedTemplate = template
                        } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let template = coordinator.selectedTemplate {
                            Image(systemName: template.icon)
                                .font(.system(size: 10))
                            Text(template.name)
                                .font(.system(size: 11))
                        } else {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                            Text("Template")
                                .font(.system(size: 11))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
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
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID
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

    private func chooseKBFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose your knowledge base folder"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
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
            await transcriptLogger.append(
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
