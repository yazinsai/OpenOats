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
        var batchStatus: BatchTranscriptionEngine.Status = .idle
    }

    @Bindable var settings: AppSettings
    @Environment(AppRuntime.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var knowledgeBase: KnowledgeBase?
    @State private var suggestionEngine: SuggestionEngine?
    @State private var overlayManager = OverlayManager()
    @State private var miniBarManager = MiniBarManager()
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
    @State private var previousBatchStatus: BatchTranscriptionEngine.Status = .idle

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
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Avoid hover-driven local state here. On macOS 26 / Swift 6.2,
                // the onHover closure triggers a view body re-evaluation outside
                // the MainActor executor context, which crashes in
                // swift_getObjectType when checking @Observable actor isolation.
                // Same class of bug fixed in ControlBar (b9625e7).
                .help("View past meeting notes")
                .accessibilityIdentifier("app.pastMeetingsButton")
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
                        .accessibilityIdentifier("app.sessionEndedBanner")
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
                        .accessibilityIdentifier("app.viewNotesButton")
                    } else {
                        Button {
                            openWindow(id: "notes")
                        } label: {
                            Label("Generate Notes", systemImage: "sparkles")
                                .font(.system(size: 12))
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

            // Batch transcription progress banner
            if case .transcribing(let progress) = viewState.batchStatus {
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
            } else if case .loading = viewState.batchStatus {
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
            } else if case .completed = viewState.batchStatus {
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
                runtime.ensureServicesInitialized(settings: settings, coordinator: coordinator)
                let kb = KnowledgeBase(settings: settings)
                let se = SuggestionEngine(
                    transcriptStore: coordinator.transcriptStore,
                    knowledgeBase: kb,
                    settings: settings
                )
                knowledgeBase = kb
                suggestionEngine = se
            }
            overlayManager.defaults = runtime.defaults
            miniBarManager.defaults = runtime.defaults
            await runtime.seedIfNeeded(coordinator: coordinator)
            refreshViewState()
            indexKBIfNeeded()
            handlePendingExternalCommandIfPossible()

            // Purge recently deleted sessions older than 24h
            await coordinator.sessionStore.purgeRecentlyDeleted()

            // Setup meeting detection if enabled
            if settings.meetingAutoDetectEnabled {
                coordinator.setupMeetingDetection(settings: settings)
                await coordinator.evaluateImmediate()
            }
        }
        .onChange(of: settings.meetingAutoDetectEnabled) {
            if settings.meetingAutoDetectEnabled {
                coordinator.setupMeetingDetection(settings: settings)
                Task {
                    await coordinator.evaluateImmediate()
                }
            } else {
                coordinator.teardownMeetingDetection()
            }
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

                // Poll batch engine status (actor-isolated)
                if let engine = coordinator.batchEngine {
                    let status = await engine.status
                    // Skip updating if idle → idle (no-op)
                    if status != .idle || coordinator.batchStatus != .idle {
                        let prev = coordinator.batchStatus
                        coordinator.batchStatus = status

                        // Send notification on completion if app is not focused
                        if case .completed(let sid) = status, prev != status {
                            if !NSApp.isActive, let notifService = coordinator.notificationService {
                                await notifService.postBatchCompleted(sessionID: sid)
                            }
                            // Refresh history so the updated transcript is visible
                            await coordinator.loadHistory()

                            // Auto-dismiss after 3 seconds
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(3))
                                if case .completed = coordinator.batchStatus {
                                    coordinator.batchStatus = .idle
                                }
                            }
                        }
                    }
                }

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

        suggestionEngine?.clear()
        coordinator.handle(.userStarted(.manual()), settings: settings)
    }

    private func stopSession() {
        coordinator.handle(.userStopped, settings: settings)
    }

    private func showMiniBar() {
        let content = MiniBarContent(
            audioLevel: audioLevel,
            suggestions: viewState.suggestions,
            isGenerating: viewState.isGeneratingSuggestions,
            onTap: {
                // Tapping the bar brings focus back to main window
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        )
        miniBarManager.show(content: content)
    }

    private func updateMiniBarContent() {
        let content = MiniBarContent(
            audioLevel: audioLevel,
            suggestions: viewState.suggestions,
            isGenerating: viewState.isGeneratingSuggestions,
            onTap: {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        )
        miniBarManager.show(content: content)
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
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handlePendingExternalCommandIfPossible() {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession:
            guard coordinator.transcriptionEngine != nil, suggestionEngine != nil, coordinator.transcriptLogger != nil else {
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
        // Reset silence timer for auto-detected sessions
        coordinator.noteUtterance()

        // Persist to transcript log
        Task {
            await coordinator.transcriptLogger?.append(
                speaker: last.speaker.displayLabel,
                text: last.text,
                timestamp: last.timestamp
            )
        }

        // Trigger transcript refinement if enabled
        if settings.enableTranscriptRefinement, let engine = coordinator.refinementEngine {
            Task {
                await engine.refine(last)
            }
        }

        // Trigger suggestions on any remote utterance
        if last.speaker.isRemote {
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
                    transcriptStore: coordinator.transcriptStore
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
        let utterances = coordinator.transcriptStore.utterances
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
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }

        var nextViewState = ViewState()
        nextViewState.isRunning = coordinator.transcriptionEngine?.isRunning ?? false
        nextViewState.lastEndedSession = lastEndedSession
        nextViewState.lastSessionHasNotes = lastSessionHasNotes
        nextViewState.modelDisplayName = activeModelRaw.split(separator: "/").last.map(String.init) ?? activeModelRaw
        nextViewState.transcriptionPrompt = settings.transcriptionModel.downloadPrompt
        nextViewState.statusMessage = coordinator.transcriptionEngine?.assetStatus
        nextViewState.errorMessage = coordinator.transcriptionEngine?.lastError
        nextViewState.needsDownload = coordinator.transcriptionEngine?.needsModelDownload ?? false
        nextViewState.kbIndexingProgress = knowledgeBase?.indexingProgress ?? ""
        nextViewState.suggestions = suggestionEngine?.suggestions ?? []
        nextViewState.isGeneratingSuggestions = suggestionEngine?.isGenerating ?? false
        nextViewState.showLiveTranscript = settings.showLiveTranscript
        nextViewState.utterances = coordinator.transcriptStore.utterances
        nextViewState.volatileYouText = coordinator.transcriptStore.volatileYouText
        nextViewState.volatileThemText = coordinator.transcriptStore.volatileThemText
        nextViewState.kbFolderPath = settings.kbFolderPath
        nextViewState.notesFolderPath = settings.notesFolderPath
        nextViewState.voyageApiKey = settings.voyageApiKey
        nextViewState.transcriptionModel = settings.transcriptionModel
        nextViewState.inputDeviceID = settings.inputDeviceID
        nextViewState.batchStatus = coordinator.batchStatus

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
                await coordinator.transcriptLogger?.updateDirectory(url)
            }
            coordinator.audioRecorder?.updateDirectory(url)
        }

        if currentViewState.voyageApiKey != observedVoyageApiKey {
            observedVoyageApiKey = currentViewState.voyageApiKey
            indexKBIfNeeded()
        }

        if currentViewState.transcriptionModel != observedTranscriptionModel {
            observedTranscriptionModel = currentViewState.transcriptionModel
            coordinator.transcriptionEngine?.refreshModelAvailability()
        }

        if currentViewState.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = currentViewState.inputDeviceID
            if currentViewState.isRunning {
                Task {
                    coordinator.transcriptionEngine?.restartMic(inputDeviceID: currentViewState.inputDeviceID)
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
            if currentViewState.isRunning {
                showMiniBar()
            } else {
                miniBarManager.hide()
            }
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
            audioLevel = coordinator.transcriptionEngine?.audioLevel ?? 0
            if miniBarManager.isVisible {
                updateMiniBarContent()
            }
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
            coordinator.transcriptionEngine?.downloadConfirmed = true
            startSession()
        }
    }
}
