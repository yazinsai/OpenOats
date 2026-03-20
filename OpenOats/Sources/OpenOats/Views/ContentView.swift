import SwiftUI
import CoreAudio

struct ContentView: View {
    private enum ControlBarAction {
        case toggle
        case confirmDownload
    }

    private struct ViewState {
        var isRunning = false
        var lastEndedSession: SessionIndex?
        var lastSessionHasNotes = false
        var modelDisplayName = ""
        var transcriptionPrompt = ""
        var statusMessage: String?
        var errorMessage: String?
        var needsDownload = false
        var kbIndexingProgress = ""
        var suggestions: [Suggestion] = []
        var isGeneratingSuggestions = false
        var showLiveTranscript = true
        var utterances: [Utterance] = []
        var volatileYouText = ""
        var volatileThemText = ""
        var kbFolderPath = ""
        var notesFolderPath = ""
        var voyageApiKey = ""
        var transcriptionModel: TranscriptionModel = .parakeetV2
        var inputDeviceID: AudioDeviceID = 0
    }

    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var transcriptStore = TranscriptStore()
    @State private var knowledgeBase: KnowledgeBase?
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var suggestionEngine: SuggestionEngine?
    @State private var transcriptLogger: TranscriptLogger?
    @State private var refinementEngine: TranscriptRefinementEngine?
    @State private var audioRecorder: AudioRecorder?
    @State private var overlayManager = OverlayManager()
    @AppStorage("isTranscriptExpanded") private var isTranscriptExpanded = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false
    @State private var audioLevel: Float = 0
    @State private var viewState = ViewState()
    @State private var pendingControlBarAction: ControlBarAction?
    @State private var observedUtteranceCount = 0
    @State private var observedIsRunning = false
    @State private var observedPendingExternalCommandID: UUID?
    @State private var observedKBFolderPath = ""
    @State private var observedNotesFolderPath = ""
    @State private var observedVoyageApiKey = ""
    @State private var observedTranscriptionModel: TranscriptionModel = .parakeetV2
    @State private var observedInputDeviceID: AudioDeviceID = 0
    @State private var isHoveringNotes = false
    @State private var isHoveringCopy = false

    var body: some View {
        bodyWithModifiers
    }

    private var rootContent: some View {
        let viewState = viewState

        return VStack(spacing: 0) {
            // Compact header
            HStack {
                Text("OpenOats")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // KB indexing status (subtle, read-only)
                if !viewState.kbIndexingProgress.isEmpty {
                    Text(viewState.kbIndexingProgress)
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
                    .background(isHoveringNotes ? Color.primary.opacity(0.06) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { hovering in isHoveringNotes = hovering }
                .help("View past meeting notes")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Post-session banner
            if let lastSession = viewState.lastEndedSession, lastSession.utteranceCount > 0 {
                HStack {
                    Text("Session ended \u{00B7} \(lastSession.utteranceCount) utterances")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewState.lastSessionHasNotes {
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
                Text("SUGGESTIONS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(1.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                SuggestionsView(
                    suggestions: viewState.suggestions,
                    isGenerating: viewState.isGeneratingSuggestions
                )
            }

            Divider()

            // Collapsible transcript (hidden when live transcript is disabled)
            if viewState.showLiveTranscript {
                DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                    TranscriptView(
                        utterances: viewState.utterances,
                        volatileYouText: viewState.volatileYouText,
                        volatileThemText: viewState.volatileThemText
                    )
                    .frame(height: 150)
                } label: {
                    HStack(spacing: 6) {
                        Text("Transcript")
                            .font(.system(size: 12, weight: .medium))
                        if !viewState.utterances.isEmpty {
                            Text("(\(viewState.utterances.count))")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if isTranscriptExpanded && !viewState.utterances.isEmpty {
                            Button {
                                copyTranscript()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                                    .background(isHoveringCopy ? Color.primary.opacity(0.06) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in isHoveringCopy = hovering }
                            .help("Copy transcript")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            // Bottom bar: live indicator + model
            ControlBar(
                isRunning: viewState.isRunning,
                audioLevel: audioLevel,
                modelDisplayName: viewState.modelDisplayName,
                transcriptionPrompt: viewState.transcriptionPrompt,
                statusMessage: viewState.statusMessage,
                errorMessage: viewState.errorMessage,
                needsDownload: viewState.needsDownload,
                onToggle: {
                    pendingControlBarAction = .toggle
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
            if !isShowing && settings.hasAcknowledgedRecordingConsent && !viewState.isRunning {
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
                refinementEngine = TranscriptRefinementEngine(
                    settings: settings,
                    transcriptStore: transcriptStore
                )
                audioRecorder = AudioRecorder(
                    outputDirectory: URL(fileURLWithPath: settings.notesFolderPath)
                )
            }
            refreshViewState()
            indexKBIfNeeded()
            handlePendingExternalCommandIfPossible()
        }
    }

    private var contentWithEventHandlers: some View {
        contentWithLifecycle
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
        }
        .task {
            refreshViewState()
            synchronizeDerivedState()

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                refreshViewState()
                synchronizeDerivedState()
            }
        }
    }

    // MARK: - Actions

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
            if settings.saveAudioRecording {
                audioRecorder?.startSession()
                transcriptionEngine?.audioRecorder = audioRecorder
            } else {
                transcriptionEngine?.audioRecorder = nil
            }
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
                transcriptLogger: transcriptLogger,
                audioRecorder: settings.saveAudioRecording ? audioRecorder : nil,
                refinementEngine: settings.enableTranscriptRefinement ? refinementEngine : nil
            )
        }
    }

    private func toggleOverlay() {
        let content = OverlayContent(
            suggestions: viewState.suggestions,
            isGenerating: viewState.isGeneratingSuggestions,
            volatileThemText: viewState.volatileThemText
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
        let lines = viewState.utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handlePendingExternalCommandIfPossible() {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession:
            guard transcriptionEngine != nil, suggestionEngine != nil, transcriptLogger != nil else {
                return
            }
            if !viewState.isRunning {
                startSession()
            }
            handled = true
        case .stopSession:
            guard viewState.isRunning else { return }
            stopSession()
            handled = true
        case .openNotes(let sessionID):
            coordinator.queueSessionSelection(sessionID)
            openWindow(id: "notes")
            handled = true
        }

        if handled {
            coordinator.completeExternalCommand(request.id)
        }
    }

    private func handleNewUtterance(_ last: Utterance) {
        // Persist to transcript log
        Task {
            await transcriptLogger?.append(
                speaker: last.speaker == .you ? "You" : "Them",
                text: last.text,
                timestamp: last.timestamp
            )
        }

        // Trigger transcript refinement if enabled
        if settings.enableTranscriptRefinement, let engine = refinementEngine {
            Task {
                await engine.refine(last)
            }
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
                    utteranceID: last.id,
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

    private func handleNewUtterances(startingAt startIndex: Int) {
        let utterances = transcriptStore.utterances
        guard startIndex < utterances.count else { return }

        for utterance in utterances[startIndex...] {
            handleNewUtterance(utterance)
        }
    }

    @MainActor
    private func refreshViewState() {
        let lastEndedSession = coordinator.lastEndedSession
        let lastSessionHasNotes = lastEndedSession.flatMap { lastSession in
            coordinator.sessionHistory.first { $0.id == lastSession.id }?.hasNotes
        } ?? false

        let activeModelRaw = switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        }

        var nextViewState = ViewState()
        nextViewState.isRunning = transcriptionEngine?.isRunning ?? false
        nextViewState.lastEndedSession = lastEndedSession
        nextViewState.lastSessionHasNotes = lastSessionHasNotes
        nextViewState.modelDisplayName = activeModelRaw.split(separator: "/").last.map(String.init) ?? activeModelRaw
        nextViewState.transcriptionPrompt = settings.transcriptionModel.downloadPrompt
        nextViewState.statusMessage = transcriptionEngine?.assetStatus
        nextViewState.errorMessage = transcriptionEngine?.lastError
        nextViewState.needsDownload = transcriptionEngine?.needsModelDownload ?? false
        nextViewState.kbIndexingProgress = knowledgeBase?.indexingProgress ?? ""
        nextViewState.suggestions = suggestionEngine?.suggestions ?? []
        nextViewState.isGeneratingSuggestions = suggestionEngine?.isGenerating ?? false
        nextViewState.showLiveTranscript = settings.showLiveTranscript
        nextViewState.utterances = transcriptStore.utterances
        nextViewState.volatileYouText = transcriptStore.volatileYouText
        nextViewState.volatileThemText = transcriptStore.volatileThemText
        nextViewState.kbFolderPath = settings.kbFolderPath
        nextViewState.notesFolderPath = settings.notesFolderPath
        nextViewState.voyageApiKey = settings.voyageApiKey
        nextViewState.transcriptionModel = settings.transcriptionModel
        nextViewState.inputDeviceID = settings.inputDeviceID

        viewState = nextViewState
    }

    @MainActor
    private func synchronizeDerivedState() {
        let currentViewState = viewState

        if currentViewState.kbFolderPath != observedKBFolderPath {
            observedKBFolderPath = currentViewState.kbFolderPath
            if currentViewState.kbFolderPath.isEmpty {
                knowledgeBase?.clear()
            } else {
                indexKBIfNeeded()
            }
        }

        if currentViewState.notesFolderPath != observedNotesFolderPath {
            observedNotesFolderPath = currentViewState.notesFolderPath
            let url = URL(fileURLWithPath: currentViewState.notesFolderPath)
            Task {
                await transcriptLogger?.updateDirectory(url)
            }
            audioRecorder?.updateDirectory(url)
        }

        if currentViewState.voyageApiKey != observedVoyageApiKey {
            observedVoyageApiKey = currentViewState.voyageApiKey
            indexKBIfNeeded()
        }

        if currentViewState.transcriptionModel != observedTranscriptionModel {
            observedTranscriptionModel = currentViewState.transcriptionModel
            transcriptionEngine?.refreshModelAvailability()
        }

        if currentViewState.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = currentViewState.inputDeviceID
            if currentViewState.isRunning {
                Task {
                    transcriptionEngine?.restartMic(inputDeviceID: currentViewState.inputDeviceID)
                }
            }
        }

        let utteranceCount = currentViewState.utterances.count
        if utteranceCount > observedUtteranceCount {
            handleNewUtterances(startingAt: observedUtteranceCount)
        }
        observedUtteranceCount = utteranceCount

        if currentViewState.isRunning != observedIsRunning {
            observedIsRunning = currentViewState.isRunning
            coordinator.isRecording = currentViewState.isRunning
        }

        let pendingExternalCommandID = coordinator.pendingExternalCommand?.id
        if pendingExternalCommandID != observedPendingExternalCommandID {
            observedPendingExternalCommandID = pendingExternalCommandID
            handlePendingExternalCommandIfPossible()
        }

        if let action = pendingControlBarAction {
            pendingControlBarAction = nil
            handleControlBarAction(action)
        }

        if currentViewState.isRunning {
            audioLevel = transcriptionEngine?.audioLevel ?? 0
        } else if audioLevel != 0 {
            audioLevel = 0
        }
    }

    @MainActor
    private func handleControlBarAction(_ action: ControlBarAction) {
        switch action {
        case .toggle:
            if viewState.isRunning {
                stopSession()
            } else {
                startSession()
            }
        case .confirmDownload:
            transcriptionEngine?.downloadConfirmed = true
            startSession()
        }
    }
}
