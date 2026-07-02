import SwiftUI

struct ContentView: View {
    /// Launch-time audio recovery must run once per process — WindowGroup can
    /// create multiple ContentView instances.
    @MainActor private static var didRunAudioRecovery = false

    private let collapsedSidebarNewNoteInset: CGFloat = 18

    @Bindable var settings: AppSettings

    // Transcription state
    @State private var transcriptStore = TranscriptStore()
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var sessionAudioRecorder = SessionAudioRecorder()
    @State private var micAudioLevel: Float = 0
    @State private var systemAudioLevel: Float = 0
    @State private var finalizationMessage: String?
    @State private var isProcessingSession = false
    @State private var isStartingSession = false
    @State private var processingStatus = "Processing session..."
    @State private var processingSessionTitle = ""

    // Session library state
    @State private var sessionLibrary = SessionLibrary()
    @State private var sessionListModel: SessionListModel?
    @State private var selectedSession: SessionSummary?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var liveSessionTitle: String = ""
    @State private var sessionStartTime: Date?
    @State private var liveSessionID: String?

    // Onboarding
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            SessionListView(
                listModel: sessionListModel ?? SessionListModel(library: sessionLibrary),
                selectedSession: $selectedSession,
                isRunning: isRunning,
                liveTitle: liveSessionTitle,
                liveStartTime: sessionStartTime,
                onStartSession: startSession
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 300, max: 420)
        } detail: {
            // Detail panel
            if isRunning {
                LiveSessionView(
                    transcriptStore: transcriptStore,
                    transcriptionEngine: transcriptionEngine,
                    settings: settings,
                    liveTitle: $liveSessionTitle,
                    sessionStartTime: sessionStartTime,
                    micAudioLevel: micAudioLevel,
                    systemAudioLevel: systemAudioLevel,
                    sessionID: liveSessionID,
                    library: sessionLibrary,
                    onStop: stopSession
                )
            } else if isProcessingSession {
                ProcessingSessionView(
                    title: processingSessionTitle.isEmpty ? liveSessionTitle : processingSessionTitle,
                    status: processingStatus
                )
            } else if let session = selectedSession {
                SessionDetailView(
                    session: session,
                    library: sessionLibrary,
                    listModel: sessionListModel ?? SessionListModel(library: sessionLibrary),
                    openAIAPIKey: settings.openAIAPIKey
                )
                .id(session.id) // force recreate when selection changes
            } else {
                emptyDetailView
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .overlay {
            if showsCollapsedSidebarNewNoteButton {
                GeometryReader { proxy in
                    collapsedSidebarNewNoteButton
                        .padding(.top, collapsedSidebarNewNoteInset)
                        .padding(.trailing, collapsedSidebarNewNoteInset)
                        .offset(y: -proxy.safeAreaInsets.top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .zIndex(2)
                }
            }
        }
        .overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
            }
        }
        .onChange(of: showOnboarding) {
            if !showOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .task {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            if transcriptionEngine == nil {
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
            }
            // Initialize session list
            let model = SessionListModel(library: sessionLibrary)
            sessionListModel = model
            await sessionLibrary.backfillMissingMetadata()
            await model.load()
            // Auto-select first session
            if let first = model.sessions.first {
                selectedSession = first
            }
            // Recover combined audio for sessions that have raw stems but no mix
            // (e.g. the app crashed or was killed before finalization ran).
            // Once per process: WindowGroup can create multiple ContentView
            // instances (Cmd+N, Dock reopen), and two concurrent recovery passes
            // would collide on the deterministic temp/output paths.
            if !Self.didRunAudioRecovery {
                Self.didRunAudioRecovery = true
                let sessionIDs = model.sessions.map(\.id)
                let library = sessionLibrary
                Task.detached(priority: .utility) {
                    for sessionID in sessionIDs {
                        guard let audioFiles = await library.audioFiles(for: sessionID),
                              audioFiles.combinedURL == nil,
                              audioFiles.micURL != nil || audioFiles.systemURL != nil else { continue }
                        diagLog("[AUDIO-RECOVERY] rebuilding combined audio for \(sessionID)")
                        await SessionFinalizer.generateCombinedAudioIfPossible(
                            sessionID: sessionID,
                            library: library
                        )
                    }
                }
            }
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard let engine = transcriptionEngine else {
                if micAudioLevel != 0 { micAudioLevel = 0 }
                if systemAudioLevel != 0 { systemAudioLevel = 0 }
                return
            }
            if engine.isRunning {
                micAudioLevel = engine.micAudioLevel
                systemAudioLevel = engine.systemAudioLevel
            } else {
                if micAudioLevel != 0 { micAudioLevel = 0 }
                if systemAudioLevel != 0 { systemAudioLevel = 0 }
            }
        }
    }

    // MARK: - Empty Detail

    private var emptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.warmTextMuted.opacity(0.3))
            Text("Select a session")
                .font(.gelatoSerif(size: 22, weight: .semibold))
                .foregroundStyle(Color.warmTextSecondary)
            Text("Or tap New Note to start recording.")
                .font(.system(size: 13))
                .foregroundStyle(Color.warmTextMuted)
            if let finalizationMessage {
                Text(finalizationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warmTextMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.warmBackground)
    }

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    private var showsCollapsedSidebarNewNoteButton: Bool {
        !isRunning && columnVisibility == .detailOnly
    }

    private var collapsedSidebarNewNoteButton: some View {
        Button {
            startSession()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("New Note")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.warmCardBg)
            .foregroundStyle(Color.warmTextPrimary)
            .overlay {
                Capsule()
                    .stroke(Color.warmBorder, lineWidth: 1)
            }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func startSession() {
        // Starting while the previous session is still finalizing (or while a
        // start is already in flight) would let the old teardown destroy the new
        // session's capture and recorder state.
        guard !isProcessingSession, !isStartingSession, !isRunning else { return }
        isStartingSession = true

        liveSessionTitle = SessionMetadataIO.defaultTitle(for: Date())
        sessionStartTime = Date()
        transcriptStore.clear()
        selectedSession = nil // detail panel will show live view since isRunning is true

        Task {
            // Wait for any lingering engine teardown before touching the shared
            // recorder — engine.stop() finishes the SAME SessionAudioRecorder
            // instance this session is about to start.
            await transcriptionEngine?.stop()
            await sessionStore.startSession()
            if let url = await sessionStore.currentSessionURL {
                liveSessionID = url.deletingPathExtension().lastPathComponent
                sessionAudioRecorder.start(sessionID: liveSessionID ?? "", in: url.deletingLastPathComponent())
            } else {
                diagLog("[SESSION-START-FAIL] no session URL; audio recorder not started")
            }
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID,
                sessionStart: sessionStartTime ?? Date(),
                audioRecorder: sessionAudioRecorder
            )
            isStartingSession = false
        }
    }

    private func stopSession() {
        // The stop button stays visible until the engine actually stops — a
        // double-click must not run the finalization pipeline twice.
        guard !isProcessingSession else { return }
        let utteranceCount = transcriptStore.utterances.count
        let wordCount = transcriptStore.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let sessionID = liveSessionID
        var sessionTitle = liveSessionTitle
        let parakeetSourceUtterances = transcriptStore.utterances.chronologicallySorted
        let transcriptionMode = settings.transcriptionMode
        let openAIAPIKey = settings.openAIAPIKey
        let sessionLibrary = self.sessionLibrary
        let sessionStore = self.sessionStore
        let transcriptLogger = self.transcriptLogger
        let duration: TimeInterval?
        if let start = sessionStartTime {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = nil
        }
        isProcessingSession = true
        processingStatus = "Finalizing transcript..."
        processingSessionTitle = sessionTitle

        Task {
            diagLog("[SESSION-STOP] requested for \(sessionID ?? "unknown-session")")
            await transcriptionEngine?.stop()
            diagLog("[SESSION-STOP] engine stopped for \(sessionID ?? "unknown-session")")

            // Get session URL before ending (which clears it)
            let sessionURL = await sessionStore.currentSessionURL
            var didCleanTranscript = false

            if let sessionID {
                processingStatus = "Creating combined audio..."
                await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.generateCombinedAudioIfPossible(
                        sessionID: sessionID,
                        library: sessionLibrary
                    )
                }.value
            }

            if transcriptionMode == .openAICleanup,
               let sessionID,
               let sessionURL {
                processingStatus = "Processing transcript..."
                let sessionTitleForFinalization = sessionTitle
                let result = await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.finalizeCleanedTranscript(
                        sessionID: sessionID,
                        sessionURL: sessionURL,
                        sessionTitle: sessionTitleForFinalization,
                        apiKey: openAIAPIKey,
                        library: sessionLibrary,
                        transcriptLogger: transcriptLogger,
                        parakeetSourceUtterances: parakeetSourceUtterances
                    )
                }.value
                didCleanTranscript = result.didClean
                if let errorMessage = result.errorMessage {
                    finalizationMessage = errorMessage
                }
            }

            if let sessionID {
                processingStatus = "Generating title and detailed notes..."
                let sessionTitleForNotes = sessionTitle
                let notesResult = await Task.detached(priority: .userInitiated) {
                    await SessionFinalizer.generateNotesIfPossible(
                        sessionID: sessionID,
                        sessionTitle: sessionTitleForNotes,
                        apiKey: openAIAPIKey,
                        library: sessionLibrary
                    )
                }.value
                if let errorMessage = notesResult.errorMessage {
                    finalizationMessage = errorMessage
                }
                if let generatedTitle = notesResult.generatedTitle {
                    sessionTitle = generatedTitle
                    processingSessionTitle = generatedTitle
                }
            }

            await sessionStore.endSession()
            await transcriptLogger.endSession()

            // Create metadata sidecar
            if let url = sessionURL, !didCleanTranscript {
                await sessionLibrary.createMetadata(
                    for: url,
                    title: sessionTitle,
                    utteranceCount: utteranceCount,
                    wordCount: wordCount,
                    duration: duration
                )
            }

            if let sessionID, !sessionTitle.isEmpty {
                await sessionLibrary.updateTitle(for: sessionID, newTitle: sessionTitle)
            }

            // Refresh list and auto-select the new session
            await sessionListModel?.refresh()
            if let first = sessionListModel?.sessions.first {
                selectedSession = first
            }
            isProcessingSession = false
            processingStatus = "Processing session..."
            if didCleanTranscript || transcriptionMode != .openAICleanup {
                finalizationMessage = nil
            }
        }

        sessionStartTime = nil
        liveSessionID = nil
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

        // Log session record
        Task {
            await sessionStore.appendRecord(SessionRecord(
                speaker: last.speaker,
                text: last.text,
                timestamp: last.timestamp
            ))
        }
    }

    private func generateNotesIfPossible(sessionID: String, sessionTitle: String) async -> String? {
        guard !settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let utterances = await sessionLibrary.loadTranscript(for: sessionID)
        guard !utterances.isEmpty else { return nil }

        let transcript = formattedTranscript(from: utterances)
        let userNotes = await sessionLibrary.userNotes(for: sessionID)
        let service = OpenAINotesService()

        do {
            diagLog("[NOTES] generating notes for \(sessionID)")
            let generated = try await service.generateNotes(
                apiKey: settings.openAIAPIKey,
                sessionTitle: sessionTitle,
                userNotes: userNotes,
                transcript: transcript
            )
            await sessionLibrary.upsertGeneratedNotes(for: sessionID, text: generated.notes)
            diagLog("[NOTES] saved notes for \(sessionID)")
            return generated.shortTitle
        } catch {
            diagLog("[NOTES-FAIL] \(sessionID): \(error.localizedDescription)")
            finalizationMessage = error.localizedDescription
            return nil
        }
    }

    private func generateCombinedAudioIfPossible(sessionID: String) async {
        guard let audioFiles = await sessionLibrary.audioFiles(for: sessionID) else { return }
        let audioTiming = await sessionLibrary.audioTiming(for: sessionID)
        let outputURL = await sessionLibrary.combinedAudioOutputURL(for: sessionID)

        do {
            diagLog(
                "[AUDIO] creating combined audio for \(sessionID) " +
                "mic=\(audioFiles.micURL != nil) system=\(audioFiles.systemURL != nil)"
            )
            _ = try await SessionAudioMixer.createCombinedAudio(
                micURL: audioFiles.micURL,
                systemURL: audioFiles.systemURL,
                outputURL: outputURL,
                audioTiming: audioTiming
            )
            diagLog("[AUDIO] combined audio created for \(sessionID)")
        } catch {
            diagLog("[AUDIO-FAIL] \(sessionID): \(error.localizedDescription)")
        }
    }

    private func formattedTranscript(from utterances: [Utterance]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return utterances.map { utterance in
            "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker == .you ? "You" : "Them"): \(utterance.text)"
        }.joined(separator: "\n")
    }
}
