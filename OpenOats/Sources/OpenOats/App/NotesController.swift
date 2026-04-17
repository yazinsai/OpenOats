import AppKit
import AVFoundation
import Foundation
import Observation

// MARK: - State

struct NotesState {
    var sessionHistory: [SessionIndex] = []
    var selectedSessionID: String?
    var loadedTranscript: [SessionRecord] = []
    var loadedNotes: GeneratedNotes?
    var notesGenerationStatus: GenerationStatus = .idle
    var cleanupStatus: CleanupStatus = .idle
    var selectedTemplate: MeetingTemplate?
    var showingOriginal: Bool = false
    /// Partial markdown streamed during generation.
    var streamingMarkdown: String = ""
    /// Active tag filter for sidebar (nil = show all).
    var tagFilter: String?
    /// Directory for the currently selected session (used for image loading).
    var selectedSessionDirectory: URL?
    /// URL of the playable audio file for the selected session (nil if no audio).
    var audioFileURL: URL?
    /// Whether audio is currently playing.
    var isPlayingAudio: Bool = false
    /// Sessions whose notes were freshly generated while the user was on a different session.
    /// Cleared when the user opens that session. Used to show the blue "unread" indicator.
    var freshlyGeneratedSessionIDs: Set<String> = []
}

enum CleanupStatus: Equatable {
    case idle
    case inProgress(completed: Int, total: Int)
    case completed
    case error(String)
}

enum GenerationStatus: Equatable {
    case idle
    case generating
    case completed
    case error(String)
}

struct SessionSourceGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionIndex]
}

// MARK: - Controller

/// Owns all notes/history business logic previously embedded in NotesView.
/// NotesView becomes a pure projection of `state`.
@Observable
@MainActor
final class NotesController {
    private(set) var state = NotesState()

    private let coordinator: AppCoordinator

    /// Observation polling task for engine state mapping.
    @ObservationIgnored nonisolated(unsafe) private var engineObservationTask: Task<Void, Never>?

    /// The session ID that triggered the currently in-progress generation, if any.
    /// Used to prevent bleeding status/content onto a different session when the user switches mid-generation.
    @ObservationIgnored private var generatingSessionID: String?

    /// Audio player for session recordings.
    @ObservationIgnored private var audioPlayer: AVPlayer?
    @ObservationIgnored private var playerObservation: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        startEngineObservation()
    }

    deinit {
        engineObservationTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Called when the Notes window appears. Loads history and handles pending navigation.
    /// Returns true if a deep-link session selection was consumed (caller should switch to notes tab).
    @discardableResult
    func onAppear() async -> Bool {
        await loadHistory()

        if let requested = coordinator.consumeRequestedSessionSelection() {
            selectSession(requested)
            return true
        } else if let last = coordinator.lastEndedSession {
            selectSession(last.id)
        }
        return false
    }

    /// React to a new session ending while the Notes window is open.
    func handleLastEndedSessionChanged() async {
        if let last = coordinator.lastEndedSession {
            await loadHistory()
            selectSession(last.id)
        }
    }

    /// React to a deep-link session selection request.
    /// Returns true if a request was consumed (caller may want to switch to notes tab).
    func handleRequestedSessionSelection() -> Bool {
        if let requested = coordinator.consumeRequestedSessionSelection() {
            selectSession(requested)
            return true
        }
        return false
    }

    // MARK: - Session Selection

    func selectSession(_ sessionID: String?) {
        state.selectedSessionID = sessionID
        stopAudio()

        guard let sessionID else {
            state.loadedNotes = nil
            state.loadedTranscript = []
            state.selectedSessionDirectory = nil
            state.audioFileURL = nil
            return
        }

        state.loadedNotes = nil
        state.loadedTranscript = []
        state.audioFileURL = nil
        state.selectedSessionDirectory = coordinator.sessionRepository.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
        state.showingOriginal = false
        state.freshlyGeneratedSessionIDs.remove(sessionID)
        coordinator.batchTextCleaner.cancel()
        syncCleanupStatus()

        // If generation is running for a different session, don't show its status here
        if generatingSessionID != sessionID {
            state.notesGenerationStatus = .idle
            state.streamingMarkdown = ""
        }

        Task {
            let data = await coordinator.sessionRepository.loadSessionData(sessionID: sessionID)

            state.loadedNotes = data.notes
            state.loadedTranscript = data.transcript
            state.audioFileURL = data.audioURL

            let session = state.sessionHistory.first { $0.id == sessionID }
            if let snapID = session?.templateSnapshot?.id {
                state.selectedTemplate = coordinator.templateStore.template(for: snapID)
            } else {
                state.selectedTemplate = coordinator.templateStore.template(for: TemplateStore.genericID)
            }

            let hasAny = data.transcript.contains { $0.cleanedText != nil }
            state.cleanupStatus = hasAny ? .completed : .idle
        }
    }

    // MARK: - Audio Playback

    func toggleAudioPlayback() {
        guard let url = state.audioFileURL else { return }

        if state.isPlayingAudio {
            audioPlayer?.pause()
            state.isPlayingAudio = false
            return
        }

        if audioPlayer?.currentItem?.asset != AVURLAsset(url: url) {
            stopAudio()
            let player = AVPlayer(url: url)
            audioPlayer = player
            playerObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.state.isPlayingAudio = false
            }
        }

        audioPlayer?.play()
        state.isPlayingAudio = true
    }

    func stopAudio() {
        audioPlayer?.pause()
        if let obs = playerObservation {
            NotificationCenter.default.removeObserver(obs)
            playerObservation = nil
        }
        audioPlayer = nil
        state.isPlayingAudio = false
    }

    func revealAudioInFinder() {
        guard let url = state.audioFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Notes Generation

    func generateNotes(sessionID: String, settings: AppSettings) {
        let template = state.selectedTemplate
            ?? coordinator.templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first!

        // Capture transcript immediately — before any suspension — so session switches
        // mid-load don't swap in the wrong session's records.
        let capturedTranscript = state.loadedTranscript

        generatingSessionID = sessionID
        state.notesGenerationStatus = .generating
        state.streamingMarkdown = ""

        Task {
            let scratchpad = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)

            coordinator.notesEngine.generate(
                transcript: capturedTranscript,
                template: template,
                settings: settings,
                scratchpad: scratchpad.isEmpty ? nil : scratchpad
            ) { [weak self] in
                guard let self else { return }
                Task {
                    await self.finishGeneration(sessionID: sessionID, template: template)
                }
            }
        }
    }

    func regenerateNotes(with template: MeetingTemplate? = nil, settings: AppSettings) {
        guard let sessionID = state.selectedSessionID else { return }
        if let template {
            state.selectedTemplate = template
        }
        state.loadedNotes = nil
        generateNotes(sessionID: sessionID, settings: settings)
    }

    private func finishGeneration(sessionID: String, template: MeetingTemplate) async {
        defer { generatingSessionID = nil }

        // Always save notes to disk regardless of which session the user is now on
        if !coordinator.notesEngine.generatedMarkdown.isEmpty {
            let generatedMarkdown = coordinator.notesEngine.generatedMarkdown
            let session = state.sessionHistory.first { $0.id == sessionID }
            let heading = Self.notesHeading(title: session?.title, date: session?.startedAt ?? Date())
            let markdown = heading + generatedMarkdown

            let notes = GeneratedNotes(
                template: coordinator.templateStore.snapshot(of: template),
                generatedAt: Date(),
                markdown: markdown
            )
            await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
            await loadHistory()

            if state.selectedSessionID == sessionID {
                // User is still on this session — update UI directly
                state.loadedNotes = notes
                state.notesGenerationStatus = .completed
            } else {
                // User has moved away — show the blue "unread" badge in the sidebar
                state.freshlyGeneratedSessionIDs.insert(sessionID)
            }
            return
        } else if state.selectedSessionID == sessionID {
            if let error = coordinator.notesEngine.error {
                state.notesGenerationStatus = .error(error)
            } else {
                state.notesGenerationStatus = .idle
            }
        }
    }

    func cancelGeneration() {
        coordinator.notesEngine.cancel()
        generatingSessionID = nil
        state.notesGenerationStatus = .idle
        state.streamingMarkdown = ""
    }

    // MARK: - Image Insertion

    func insertImage(imageData: Data) {
        guard let sessionID = state.selectedSessionID else { return }

        Task {
            let filename = await coordinator.sessionRepository.saveImage(
                sessionID: sessionID, imageData: imageData
            )
            let imageRef = "\n\n![](images/\(filename))\n"

            if let existing = state.loadedNotes {
                let updated = GeneratedNotes(
                    template: existing.template,
                    generatedAt: existing.generatedAt,
                    markdown: existing.markdown + imageRef
                )
                await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: updated)
                state.loadedNotes = updated
            } else {
                let template = state.selectedTemplate
                    ?? coordinator.templateStore.template(for: TemplateStore.genericID)
                    ?? TemplateStore.builtInTemplates.first!
                let notes = GeneratedNotes(
                    template: coordinator.templateStore.snapshot(of: template),
                    generatedAt: Date(),
                    markdown: "![](images/\(filename))"
                )
                await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
                state.loadedNotes = notes
                await loadHistory()
            }
        }
    }

    // MARK: - Transcript Cleanup

    func cleanUpTranscript(settings: AppSettings) {
        guard let sessionID = state.selectedSessionID, !state.loadedTranscript.isEmpty else { return }

        Task {
            let updated = await coordinator.batchTextCleaner.cleanup(
                records: state.loadedTranscript,
                settings: settings
            )

            let utterances = updated.map { record in
                Utterance(
                    text: record.text,
                    speaker: record.speaker,
                    timestamp: record.timestamp,
                    cleanedText: record.cleanedText
                )
            }
            await coordinator.sessionRepository.backfillCleanedText(sessionID: sessionID, from: utterances)

            guard state.selectedSessionID == sessionID else { return }
            let newTranscript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
            state.loadedTranscript = newTranscript
            
            let hasAny = newTranscript.contains { $0.cleanedText != nil }
            state.cleanupStatus = hasAny ? .completed : .idle
        }
    }

    func cancelCleanup() {
        coordinator.batchTextCleaner.cancel()
        syncCleanupStatus()
    }

    func toggleShowingOriginal() {
        state.showingOriginal.toggle()
    }

    // MARK: - Session Management

    func renameSession(sessionID: String, newTitle: String) {
        Task {
            await coordinator.sessionRepository.renameSession(sessionID: sessionID, title: newTitle)
            await loadHistory()
        }
    }

    func deleteSession(sessionID: String) {
        Task {
            await coordinator.sessionRepository.deleteSession(sessionID: sessionID)
            if state.selectedSessionID == sessionID {
                state.selectedSessionID = nil
                state.loadedNotes = nil
                state.loadedTranscript = []
            }
            await loadHistory()
        }
    }

    func deleteSessions(sessionIDs: Set<String>) {
        Task {
            for id in sessionIDs {
                await coordinator.sessionRepository.deleteSession(sessionID: id)
            }
            if let selected = state.selectedSessionID, sessionIDs.contains(selected) {
                state.selectedSessionID = nil
                state.loadedNotes = nil
                state.loadedTranscript = []
            }
            await loadHistory()
        }
    }

    // MARK: - Tags

    /// Sessions filtered by active tag filter.
    var filteredSessions: [SessionIndex] {
        guard let filter = state.tagFilter else { return state.sessionHistory }
        return state.sessionHistory.filter { session in
            Self.visibleTags(for: session).contains {
                $0.localizedCaseInsensitiveCompare(filter) == .orderedSame
            }
        }
    }

    var sessionSourceGroups: [SessionSourceGroup] {
        let grouped = Dictionary(grouping: filteredSessions, by: Self.sourceGroupKey(for:))
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            let lhsOrder = Self.sourceGroupSortOrder(for: lhs)
            let rhsOrder = Self.sourceGroupSortOrder(for: rhs)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return Self.sourceDisplayName(for: lhs).localizedCaseInsensitiveCompare(
                Self.sourceDisplayName(for: rhs)
            ) == .orderedAscending
        }
        return orderedKeys.map { key in
            SessionSourceGroup(
                id: key,
                title: Self.sourceDisplayName(for: key),
                sessions: grouped[key] ?? []
            )
        }
    }

    var showsSourceSections: Bool {
        let groups = sessionSourceGroups
        guard !groups.isEmpty else { return false }
        return groups.count > 1 || groups.first?.id != "openoats"
    }

    func updateSessionTags(sessionID: String, tags: [String]) {
        Task {
            await coordinator.sessionRepository.updateSessionTags(sessionID: sessionID, tags: tags)
            await loadHistory()
        }
    }

    func setTagFilter(_ tag: String?) {
        state.tagFilter = tag
    }

    func allTags() async -> [String] {
        await coordinator.sessionRepository.allTags().filter(Self.isUserVisibleSessionTag(_:))
    }

    static func visibleTags(for session: SessionIndex) -> [String] {
        visibleTags(from: session.tags)
    }

    static func visibleTags(from tags: [String]?) -> [String] {
        (tags ?? []).filter(isUserVisibleSessionTag)
    }

    static func isUserVisibleSessionTag(_ tag: String) -> Bool {
        !tag.lowercased().hasPrefix("granola:")
    }

    static func sourceGroupKey(for session: SessionIndex) -> String {
        guard let rawSource = session.source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty else {
            return "openoats"
        }
        return rawSource.lowercased()
    }

    static func sourceDisplayName(for sourceKey: String) -> String {
        switch sourceKey {
        case "openoats":
            "OpenOats"
        case "granola":
            "Granola"
        default:
            sourceKey.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private static func sourceGroupSortOrder(for sourceKey: String) -> Int {
        switch sourceKey {
        case "openoats":
            0
        case "granola":
            1
        default:
            2
        }
    }

    // MARK: - Accessors

    /// Templates available for generation.
    var availableTemplates: [MeetingTemplate] {
        coordinator.templateStore.templates
    }

    /// Notes engine error for display (when not yet mapped to status).
    var notesEngineError: String? {
        coordinator.notesEngine.error
    }

    /// True whenever any session's notes are being generated.
    var isAnyGenerationInProgress: Bool {
        generatingSessionID != nil
    }

    /// Returns true if the given session is currently being generated.
    func isGenerating(sessionID: String) -> Bool {
        generatingSessionID == sessionID
    }

    /// Display name of the session currently being generated (for tooltip messaging).
    var generatingSessionName: String {
        guard let id = generatingSessionID else { return "" }
        let title = state.sessionHistory.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    // MARK: - Private

    func loadHistory() async {
        state.sessionHistory = await coordinator.sessionRepository.listSessions()
    }

    /// Builds a markdown heading for generated notes.
    static func notesHeading(title: String?, date: Date) -> String {
        let displayTitle: String
        if let title, !title.isEmpty {
            displayTitle = title
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            displayTitle = formatter.string(from: date)
        }
        return "# Meeting Notes: \(displayTitle)\n\n"
    }

    /// Maps engine observable state to our flat status enums.
    private func startEngineObservation() {
        engineObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.syncCleanupStatus()
                self.syncGenerationStatus()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func syncCleanupStatus() {
        let engine = coordinator.batchTextCleaner

        if engine.isCleaningUp {
            let newStatus = CleanupStatus.inProgress(
                completed: engine.chunksCompleted,
                total: engine.totalChunks
            )
            if state.cleanupStatus != newStatus {
                state.cleanupStatus = newStatus
            }
        } else if let error = engine.error {
            if state.cleanupStatus != .error(error) {
                state.cleanupStatus = .error(error)
            }
        }
    }

    private func syncGenerationStatus() {
        let engine = coordinator.notesEngine
        // Only propagate engine state if the generation belongs to the currently selected session
        guard engine.isGenerating, generatingSessionID == state.selectedSessionID else { return }
        if state.notesGenerationStatus != .generating {
            state.notesGenerationStatus = .generating
        }
        if state.streamingMarkdown != engine.generatedMarkdown {
            state.streamingMarkdown = engine.generatedMarkdown
        }
    }
}
