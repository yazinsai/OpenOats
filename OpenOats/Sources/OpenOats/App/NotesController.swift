import AppKit
import AVFoundation
import Foundation
import Observation

// MARK: - State

struct NotesState {
    var sessionHistory: [SessionIndex] = []
    var selectedSessionID: String?
    var selectedMeetingFamily: MeetingFamilySelection?
    var meetingHistoryEntries: [MeetingHistoryEntry] = []
    var meetingFamilyKnowledgeBaseCoverage: MeetingFamilyKnowledgeBaseCoverage?
    var isMeetingFamilyKnowledgeBaseLoading: Bool = false
    var relatedMeetingSuggestions: [MeetingHistorySuggestion] = []
    var linkingMeetingSuggestionKey: String?
    var loadedTranscript: [SessionRecord] = []
    var loadedNotes: GeneratedNotes?
    var manualNotesDraft: String = ""
    var savedManualNotesMarkdown: String = ""
    var isEditingManualNotes: Bool = false
    var loadedCalendarEvent: CalendarEvent?
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
    /// All playable audio sources for the selected session.
    var availableAudioSources: [SessionAudioSource] = []
    /// URL of the currently selected playable audio source for the session (nil if no audio).
    var audioFileURL: URL?
    /// Whether audio is currently playing.
    var isPlayingAudio: Bool = false
    /// Sessions whose notes were freshly generated while the user was on a different session.
    /// Cleared when the user opens that session. Used to show the blue "unread" indicator.
    var freshlyGeneratedSessionIDs: Set<String> = []

    var selectedMeetingHistory: MeetingHistorySelection? {
        guard let event = selectedMeetingFamily?.upcomingEvent else { return nil }
        return MeetingHistorySelection(event: event)
    }
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

struct SessionFolderGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionIndex]
}

struct MeetingFamilySelection: Equatable {
    let key: String
    let title: String
    let calendarTitle: String?
    let upcomingEvent: CalendarEvent?
}

struct MeetingHistorySelection: Equatable {
    let event: CalendarEvent

    var key: String { MeetingHistoryResolver.historyKey(for: event) }
}

struct MeetingHistoryEntry: Identifiable {
    let session: SessionIndex
    let notesPreview: String?
    let hasAudio: Bool

    var id: String { session.id }
}

struct MeetingHistorySuggestion: Identifiable, Equatable {
    let key: String
    let title: String
    let sessionCount: Int
    let notesCount: Int
    let latestStartedAt: Date

    var id: String { key }
}

struct MeetingFamilyKnowledgeBaseDocument: Identifiable, Equatable {
    let relativePath: String
    let title: String
    let score: Double

    var id: String { relativePath }
}

struct MeetingFamilyKnowledgeBaseCoverage: Equatable {
    let documentCount: Int
    let topDocuments: [MeetingFamilyKnowledgeBaseDocument]

    var badgeText: String {
        "Knowledge available"
    }

    var helpText: String {
        guard !topDocuments.isEmpty else { return "Knowledge base context is available for this meeting family." }

        let lines = topDocuments.enumerated().map { offset, document in
            "\(offset + 1). \(document.title)"
        }
        return "Relevant knowledge base documents:\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Controller

/// Owns all notes/history business logic previously embedded in NotesView.
/// NotesView becomes a pure projection of `state`.
@Observable
@MainActor
final class NotesController {
    private(set) var state = NotesState()

    private let coordinator: AppCoordinator
    private let settings: AppSettings?

    /// Observation polling task for engine state mapping.
    @ObservationIgnored nonisolated(unsafe) private var engineObservationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var meetingHistoryPreviewTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var meetingFamilyKnowledgeBaseTask: Task<Void, Never>?
    @ObservationIgnored private var unsavedManualNotesDraftsBySessionID: [String: String] = [:]

    /// The session ID that triggered the currently in-progress generation, if any.
    /// Used to prevent bleeding status/content onto a different session when the user switches mid-generation.
    @ObservationIgnored private var generatingSessionID: String?
    @ObservationIgnored private var cancelledGenerationSessionIDs: Set<String> = []

    /// Audio player for session recordings.
    @ObservationIgnored private var audioPlayer: AVPlayer?
    @ObservationIgnored private var playerObservation: Any?

    init(coordinator: AppCoordinator, settings: AppSettings? = nil) {
        self.coordinator = coordinator
        self.settings = settings
        startEngineObservation()
    }

    deinit {
        engineObservationTask?.cancel()
        meetingHistoryPreviewTask?.cancel()
        meetingFamilyKnowledgeBaseTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Called when the Notes window appears. Loads history and handles pending navigation.
    /// Returns true if a deep-link session selection was consumed (caller should switch to notes tab).
    @discardableResult
    func onAppear() async -> Bool {
        await loadHistory()

        if let requested = coordinator.consumeRequestedSessionSelection() {
            switch requested {
            case .session(let sessionID):
                selectSession(sessionID)
                return true
            case .meetingHistory(let event):
                showMeetingFamily(for: event)
                return true
            case .clearSelection:
                selectSession(nil)
                return true
            }
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
            switch requested {
            case .session(let sessionID):
                selectSession(sessionID)
            case .meetingHistory(let event):
                showMeetingFamily(for: event)
            case .clearSelection:
                selectSession(nil)
            }
            return true
        }
        return false
    }

    // MARK: - Session Selection

    func selectSession(_ sessionID: String?) {
        persistCurrentManualNotesDraftIfNeeded()
        cancelMeetingHistoryPreviewHydration()
        cancelMeetingFamilyKnowledgeBaseLoad()
        state.selectedSessionID = sessionID
        state.selectedMeetingFamily = nil
        state.meetingHistoryEntries = []
        state.relatedMeetingSuggestions = []
        state.linkingMeetingSuggestionKey = nil
        stopAudio()

        guard let sessionID else {
            state.loadedNotes = nil
            state.manualNotesDraft = ""
            state.savedManualNotesMarkdown = ""
            state.isEditingManualNotes = false
            state.loadedTranscript = []
            state.loadedCalendarEvent = nil
            state.selectedSessionDirectory = nil
            state.availableAudioSources = []
            state.audioFileURL = nil
            return
        }

        state.loadedNotes = nil
        state.manualNotesDraft = ""
        state.savedManualNotesMarkdown = ""
        state.isEditingManualNotes = false
        state.loadedTranscript = []
        state.loadedCalendarEvent = nil
        state.availableAudioSources = []
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
            let unsavedDraft = unsavedManualNotesDraftsBySessionID[sessionID]

            state.loadedNotes = data.notes
            state.manualNotesDraft = unsavedDraft ?? data.notes?.markdown ?? ""
            state.savedManualNotesMarkdown = data.notes?.markdown ?? ""
            state.isEditingManualNotes = unsavedDraft != nil
            state.loadedTranscript = data.transcript
            state.loadedCalendarEvent = data.calendarEvent
            state.availableAudioSources = data.audioSources
            state.audioFileURL = data.audioURL

            let session = state.sessionHistory.first { $0.id == sessionID }
            let familySelection = session.map { Self.meetingFamilySelection(for: $0, calendarEvent: data.calendarEvent) }
            state.selectedTemplate = selectedTemplate(
                forSessionTemplateID: session?.templateSnapshot?.id,
                meetingFamilyKey: familySelection?.key
            )

            if let familySelection {
                state.selectedMeetingFamily = familySelection
                presentMeetingHistory(for: familySelection)
            }

            let hasAny = data.transcript.contains { $0.cleanedText != nil }
            state.cleanupStatus = hasAny ? .completed : .idle
        }
    }

    func showMeetingFamily(for event: CalendarEvent) {
        persistCurrentManualNotesDraftIfNeeded()
        cancelMeetingHistoryPreviewHydration()
        cancelMeetingFamilyKnowledgeBaseLoad()
        state.selectedSessionID = nil
        let selection = Self.meetingFamilySelection(for: event)
        state.selectedMeetingFamily = selection
        state.meetingHistoryEntries = []
        state.relatedMeetingSuggestions = []
        state.linkingMeetingSuggestionKey = nil
        stopAudio()

        state.loadedNotes = nil
        state.manualNotesDraft = ""
        state.savedManualNotesMarkdown = ""
        state.isEditingManualNotes = false
        state.loadedTranscript = []
        state.loadedCalendarEvent = nil
        state.selectedSessionDirectory = nil
        state.availableAudioSources = []
        state.audioFileURL = nil
        state.showingOriginal = false
        state.selectedTemplate = selectedTemplate(
            forSessionTemplateID: nil,
            meetingFamilyKey: selection.key
        )
        coordinator.batchTextCleaner.cancel()
        syncCleanupStatus()
        presentMeetingHistory(for: selection)
    }

    func showMeetingHistory(for event: CalendarEvent) {
        showMeetingFamily(for: event)
    }

    func linkMeetingHistorySuggestion(_ suggestion: MeetingHistorySuggestion) {
        guard let settings, let selection = state.selectedMeetingFamily else { return }
        state.linkingMeetingSuggestionKey = suggestion.key
        settings.linkMeetingHistoryAlias(from: suggestion.key, to: selection.key)

        Task {
            await Task.yield()
            guard state.selectedMeetingFamily?.key == selection.key else { return }
            presentMeetingHistory(for: selection)
            state.linkingMeetingSuggestionKey = nil
        }
    }

    func showCurrentMeetingFamilyOverview() {
        guard state.selectedMeetingFamily != nil else { return }
        persistCurrentManualNotesDraftIfNeeded()
        state.selectedSessionID = nil
        stopAudio()
        state.loadedNotes = nil
        state.manualNotesDraft = ""
        state.savedManualNotesMarkdown = ""
        state.isEditingManualNotes = false
        state.loadedTranscript = []
        state.loadedCalendarEvent = nil
        state.availableAudioSources = []
        state.audioFileURL = nil
        state.selectedSessionDirectory = nil
        state.showingOriginal = false
        coordinator.batchTextCleaner.cancel()
        syncCleanupStatus()
    }

    // MARK: - Audio Playback

    func toggleAudioPlayback(source: SessionAudioSource? = nil) {
        let targetURL = source?.url ?? state.audioFileURL ?? state.availableAudioSources.first?.url
        guard let targetURL else { return }

        let currentPlayerURL = (audioPlayer?.currentItem?.asset as? AVURLAsset)?.url
        state.audioFileURL = targetURL

        if state.isPlayingAudio, currentPlayerURL == targetURL {
            audioPlayer?.pause()
            state.isPlayingAudio = false
            return
        }

        if currentPlayerURL != targetURL {
            stopAudio()
            let player = AVPlayer(url: targetURL)
            audioPlayer = player
            playerObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.state.isPlayingAudio = false
                }
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
        guard let url = state.audioFileURL ?? state.availableAudioSources.first?.url else { return }
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
        let capturedCalendarEvent = state.loadedCalendarEvent

        generatingSessionID = sessionID
        cancelledGenerationSessionIDs.remove(sessionID)
        state.notesGenerationStatus = .generating
        state.streamingMarkdown = ""

        Task {
            let scratchpad = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)

            coordinator.notesEngine.generate(
                transcript: capturedTranscript,
                template: template,
                settings: settings,
                calendarEvent: capturedCalendarEvent,
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

        if cancelledGenerationSessionIDs.remove(sessionID) != nil {
            if state.selectedSessionID == sessionID {
                state.notesGenerationStatus = .idle
                state.streamingMarkdown = ""
            }
            return
        }

        // Always save notes to disk regardless of which session the user is now on
        if !coordinator.notesEngine.generatedMarkdown.isEmpty {
            let generatedMarkdown = coordinator.notesEngine.generatedMarkdown
            let session = state.sessionHistory.first { $0.id == sessionID }
            let markdown = Self.normalizedNotesMarkdown(
                generatedMarkdown,
                title: session?.title,
                date: session?.startedAt ?? Date()
            )

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
                state.manualNotesDraft = notes.markdown
                state.savedManualNotesMarkdown = notes.markdown
                state.isEditingManualNotes = notes.markdown.isEmpty == false || state.loadedTranscript.isEmpty
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
        if let sessionID = generatingSessionID {
            cancelledGenerationSessionIDs.insert(sessionID)
        }
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
            let isManualNotesSession = state.loadedTranscript.isEmpty

            if let existing = state.loadedNotes {
                let baseMarkdown = isManualNotesSession ? state.manualNotesDraft : existing.markdown
                let updated = GeneratedNotes(
                    template: existing.template,
                    generatedAt: existing.generatedAt,
                    markdown: baseMarkdown + imageRef
                )
                await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: updated)
                state.loadedNotes = updated
                state.manualNotesDraft = updated.markdown
                state.savedManualNotesMarkdown = updated.markdown
            } else {
                let template = state.selectedTemplate
                    ?? coordinator.templateStore.template(for: TemplateStore.genericID)
                    ?? TemplateStore.builtInTemplates.first!
                let baseMarkdown = isManualNotesSession ? state.manualNotesDraft : ""
                let notes = GeneratedNotes(
                    template: coordinator.templateStore.snapshot(of: template),
                    generatedAt: Date(),
                    markdown: baseMarkdown + (baseMarkdown.isEmpty ? "" : "\n\n") + "![](images/\(filename))"
                )
                await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
                state.loadedNotes = notes
                state.manualNotesDraft = notes.markdown
                state.savedManualNotesMarkdown = notes.markdown
                await loadHistory()
            }
        }
    }

    // MARK: - Manual Notes

    func updateManualNotesDraft(_ markdown: String) {
        state.manualNotesDraft = markdown
        state.isEditingManualNotes = true
        guard let sessionID = state.selectedSessionID else { return }
        if markdown == state.savedManualNotesMarkdown {
            unsavedManualNotesDraftsBySessionID.removeValue(forKey: sessionID)
        } else {
            unsavedManualNotesDraftsBySessionID[sessionID] = markdown
        }
    }

    func startManualNotesEditing() {
        state.isEditingManualNotes = true
    }

    func discardManualNotesDraft() {
        state.manualNotesDraft = state.savedManualNotesMarkdown
        state.isEditingManualNotes = false
        if let sessionID = state.selectedSessionID {
            unsavedManualNotesDraftsBySessionID.removeValue(forKey: sessionID)
        }
    }

    func saveManualNotes() {
        guard let sessionID = state.selectedSessionID else { return }

        let template = state.loadedNotes.flatMap { existing in
            coordinator.templateStore.template(for: existing.template.id)
        } ?? state.selectedTemplate
            ?? coordinator.templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first!
        let existingGeneratedAt = state.loadedNotes?.generatedAt
        let markdown = state.manualNotesDraft

        Task {
            let notes = GeneratedNotes(
                template: coordinator.templateStore.snapshot(of: template),
                generatedAt: existingGeneratedAt ?? Date(),
                markdown: markdown
            )
            await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
            await loadHistory()

            guard state.selectedSessionID == sessionID else { return }
            state.loadedNotes = notes
            state.manualNotesDraft = notes.markdown
            state.savedManualNotesMarkdown = notes.markdown
            state.isEditingManualNotes = false
            unsavedManualNotesDraftsBySessionID.removeValue(forKey: sessionID)
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
                state.loadedCalendarEvent = nil
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
                state.loadedCalendarEvent = nil
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

    var rootFolderSessions: [SessionIndex] {
        guard showsFolderSections else { return [] }
        return filteredSessions.filter { Self.normalizedFolderPath(for: $0)?.isEmpty != false }
    }

    var folderGroups: [SessionFolderGroup] {
        let grouped = Dictionary(
            grouping: filteredSessions.compactMap { session -> (String, SessionIndex)? in
                guard let folderPath = Self.normalizedFolderPath(for: session), !folderPath.isEmpty else {
                    return nil
                }
                return (folderPath, session)
            },
            by: \.0
        )
        let orderedKeys = grouped.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return orderedKeys.map { key in
            SessionFolderGroup(
                id: key,
                title: Self.folderDisplayName(for: key),
                sessions: (grouped[key] ?? []).map(\.1)
            )
        }
    }

    var showsFolderSections: Bool {
        filteredSessions.contains { Self.normalizedFolderPath(for: $0)?.isEmpty == false }
    }

    func updateSessionTags(sessionID: String, tags: [String]) {
        Task {
            await coordinator.sessionRepository.updateSessionTags(sessionID: sessionID, tags: tags)
            await loadHistory()
        }
    }

    func updateSessionFolder(sessionID: String, folderPath: String?) {
        Task {
            await coordinator.sessionRepository.updateSessionFolder(sessionID: sessionID, folderPath: folderPath)
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

    static func normalizedFolderPath(for session: SessionIndex) -> String? {
        NotesFolderDefinition.normalizePath(session.folderPath ?? "")
    }

    static func folderDisplayName(for folderPath: String) -> String {
        folderPath
            .split(separator: "/")
            .map(String.init)
            .joined(separator: " › ")
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

    func selectTemplate(_ template: MeetingTemplate) {
        state.selectedTemplate = template
    }

    func setSelectedTemplateSavedForMeetingFamily(_ enabled: Bool) {
        guard let settings,
              let selection = state.selectedMeetingFamily else { return }

        if enabled {
            guard let template = state.selectedTemplate else { return }
            settings.setMeetingFamilyTemplatePreference(template.id, forHistoryKey: selection.key)
        } else {
            settings.setMeetingFamilyTemplatePreference(nil, forHistoryKey: selection.key)
        }
    }

    func setMeetingFamilyFolderPreference(_ folderPath: String?) {
        guard let settings,
              let selection = state.selectedMeetingFamily else { return }
        settings.setMeetingFamilyFolderPreference(folderPath, forHistoryKey: selection.key)
    }

    func applyMeetingFamilyFolderPreference(
        _ folderPath: String?,
        moveExistingSessions: Bool,
        forHistoryKey historyKey: String? = nil
    ) {
        guard let settings else { return }
        let key = historyKey ?? state.selectedMeetingFamily?.key
        guard let key, !key.isEmpty else { return }

        settings.setMeetingFamilyFolderPreference(folderPath, forHistoryKey: key)

        guard moveExistingSessions else { return }

        let sessionIDs = MeetingHistoryResolver.matchingSessions(
            forHistoryKey: key,
            sessionHistory: state.sessionHistory,
            aliases: settings.meetingHistoryAliasesByKey
        ).map(\.id)

        Task {
            for sessionID in sessionIDs {
                await coordinator.sessionRepository.updateSessionFolder(sessionID: sessionID, folderPath: folderPath)
            }
            await loadHistory()
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

    var isManualNotesSession: Bool {
        state.selectedSessionID != nil && state.loadedTranscript.isEmpty
    }

    var hasUnsavedManualNotesChanges: Bool {
        guard isManualNotesSession else { return false }
        return state.manualNotesDraft != state.savedManualNotesMarkdown
    }

    // MARK: - Private

    private func selectedTemplate(
        forSessionTemplateID sessionTemplateID: UUID?,
        meetingFamilyKey: String?
    ) -> MeetingTemplate? {
        if let sessionTemplateID,
           sessionTemplateID != TemplateStore.genericID,
           let template = coordinator.templateStore.template(for: sessionTemplateID) {
            return template
        }

        if let meetingFamilyKey,
           let preferredID = settings?.meetingFamilyPreferences(forHistoryKey: meetingFamilyKey)?.templateID,
           let template = coordinator.templateStore.template(for: preferredID) {
            return template
        }

        if let sessionTemplateID,
           let template = coordinator.templateStore.template(for: sessionTemplateID) {
            return template
        }

        return coordinator.templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first
    }

    private func persistCurrentManualNotesDraftIfNeeded() {
        guard let sessionID = state.selectedSessionID, state.loadedTranscript.isEmpty else { return }
        if state.manualNotesDraft.isEmpty || state.manualNotesDraft == state.savedManualNotesMarkdown {
            unsavedManualNotesDraftsBySessionID.removeValue(forKey: sessionID)
        } else {
            unsavedManualNotesDraftsBySessionID[sessionID] = state.manualNotesDraft
        }
    }

    func loadHistory() async {
        state.sessionHistory = await coordinator.sessionRepository.listSessions()
        if let selection = state.selectedMeetingFamily {
            presentMeetingHistory(for: selection)
        }
    }

    static func normalizedNotesMarkdown(_ markdown: String, title: String?, date: Date) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return notesHeading(title: title, date: date)
        }

        let firstLine = trimmed
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.hasPrefix("# ") {
            return trimmed
        }

        return notesHeading(title: title, date: date) + trimmed
    }

    /// Builds a markdown heading for generated notes when the model does not provide one.
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

    private func matchingMeetingHistorySessions(for selection: MeetingFamilySelection) -> [SessionIndex] {
        MeetingHistoryResolver.matchingSessions(
            forHistoryKey: selection.key,
            sessionHistory: state.sessionHistory,
            aliases: settings?.meetingHistoryAliasesByKey ?? [:]
        )
    }

    private func presentMeetingHistory(for selection: MeetingFamilySelection) {
        cancelMeetingHistoryPreviewHydration()
        loadMeetingFamilyKnowledgeBaseCoverage(for: selection)

        let sessions = matchingMeetingHistorySessions(for: selection)
        let entries = sessions.map { MeetingHistoryEntry(session: $0, notesPreview: nil, hasAudio: false) }
        state.meetingHistoryEntries = entries
        state.relatedMeetingSuggestions = loadMeetingHistorySuggestions(
            for: selection,
            hasExactHistory: !entries.isEmpty
        )

        guard !sessions.isEmpty else { return }
        startMeetingHistoryPreviewHydration(for: selection, sessions: sessions)
    }

    private func startMeetingHistoryPreviewHydration(
        for selection: MeetingFamilySelection,
        sessions: [SessionIndex]
    ) {
        meetingHistoryPreviewTask = Task { [weak self] in
            guard let self else { return }

            for session in sessions {
                if Task.isCancelled { return }

                let notes = await coordinator.sessionRepository.loadNotes(sessionID: session.id)
                let hasAudio = !(await coordinator.sessionRepository.audioSources(for: session.id)).isEmpty
                let preview = notes.flatMap { Self.notesPreview(from: $0.markdown) }

                guard state.selectedMeetingFamily?.key == selection.key else { return }
                guard let index = state.meetingHistoryEntries.firstIndex(where: { $0.session.id == session.id }) else {
                    continue
                }

                if state.meetingHistoryEntries[index].notesPreview != preview
                    || state.meetingHistoryEntries[index].hasAudio != hasAudio {
                    state.meetingHistoryEntries[index] = MeetingHistoryEntry(
                        session: state.meetingHistoryEntries[index].session,
                        notesPreview: preview,
                        hasAudio: hasAudio
                    )
                }
            }
        }
    }

    private func cancelMeetingHistoryPreviewHydration() {
        meetingHistoryPreviewTask?.cancel()
        meetingHistoryPreviewTask = nil
    }

    private func loadMeetingFamilyKnowledgeBaseCoverage(for selection: MeetingFamilySelection) {
        cancelMeetingFamilyKnowledgeBaseLoad()

        guard let settings,
              settings.kbFolderURL != nil,
              let knowledgeBase = coordinator.knowledgeBase else {
            return
        }

        let query = selection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.localizedCaseInsensitiveCompare("Untitled") != .orderedSame else {
            return
        }

        state.isMeetingFamilyKnowledgeBaseLoading = true

        meetingFamilyKnowledgeBaseTask = Task { [weak self] in
            guard let self else { return }

            let packs = await knowledgeBase.searchContextPacks(queries: [query], topK: 5)
            let coverage = Self.meetingFamilyKnowledgeBaseCoverage(from: packs)

            guard state.selectedMeetingFamily?.key == selection.key else { return }
            state.meetingFamilyKnowledgeBaseCoverage = coverage
            state.isMeetingFamilyKnowledgeBaseLoading = false
        }
    }

    private func cancelMeetingFamilyKnowledgeBaseLoad() {
        meetingFamilyKnowledgeBaseTask?.cancel()
        meetingFamilyKnowledgeBaseTask = nil
        state.meetingFamilyKnowledgeBaseCoverage = nil
        state.isMeetingFamilyKnowledgeBaseLoading = false
    }

    private func loadMeetingHistorySuggestions(
        for selection: MeetingFamilySelection,
        hasExactHistory _: Bool
    ) -> [MeetingHistorySuggestion] {
        let aliases = settings?.meetingHistoryAliasesByKey ?? [:]
        let canonicalSelectionKey = MeetingHistoryResolver.canonicalHistoryKey(
            for: selection.key,
            aliases: aliases
        )

        var groupedSessions: [String: [SessionIndex]] = [:]
        for session in state.sessionHistory {
            let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let historyKey = MeetingHistoryResolver.historyKey(for: title)
            guard !historyKey.isEmpty else { continue }

            let canonicalSessionKey = MeetingHistoryResolver.canonicalHistoryKey(
                for: historyKey,
                aliases: aliases
            )
            guard canonicalSessionKey != canonicalSelectionKey else { continue }
            guard MeetingHistoryResolver.relationScore(
                from: canonicalSelectionKey,
                to: canonicalSessionKey
            ) != nil else { continue }

            groupedSessions[canonicalSessionKey, default: []].append(session)
        }

        let suggestions: [MeetingHistorySuggestion] = groupedSessions.compactMap { entry in
            let (key, sessions) = entry
            let sortedSessions = sessions.sorted { $0.startedAt > $1.startedAt }
            guard let latestSession = sortedSessions.first else { return nil }
            let title = latestSession.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = (title?.isEmpty == false ? title : nil) ?? "Untitled"
            return MeetingHistorySuggestion(
                key: key,
                title: displayTitle,
                sessionCount: sortedSessions.count,
                notesCount: sortedSessions.filter(\.hasNotes).count,
                latestStartedAt: latestSession.startedAt
            )
        }
        .sorted { lhs, rhs in
            let lhsScore = MeetingHistoryResolver.relationScore(from: canonicalSelectionKey, to: lhs.key) ?? 0
            let rhsScore = MeetingHistoryResolver.relationScore(from: canonicalSelectionKey, to: rhs.key) ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
            return lhs.latestStartedAt > rhs.latestStartedAt
        }

        let selectionTokenCount = canonicalSelectionKey.split(separator: " ").count
        if selectionTokenCount == 1 {
            let recurringSuggestions = suggestions.filter { $0.sessionCount >= 2 }
            if !recurringSuggestions.isEmpty {
                if let primary = recurringSuggestions.first {
                    let nextCount = recurringSuggestions.dropFirst().first?.sessionCount ?? 0
                    if primary.sessionCount >= max(6, nextCount * 3) {
                        return [primary]
                    }
                }
                return recurringSuggestions
            }
        }

        return suggestions
    }

    private static func meetingFamilySelection(
        for session: SessionIndex,
        calendarEvent: CalendarEvent?
    ) -> MeetingFamilySelection {
        let trimmedTitle = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let key = MeetingHistoryResolver.historyKey(for: title)
        return MeetingFamilySelection(
            key: key,
            title: title,
            calendarTitle: calendarEvent?.calendarTitle,
            upcomingEvent: nil
        )
    }

    private static func meetingFamilySelection(for event: CalendarEvent) -> MeetingFamilySelection {
        MeetingFamilySelection(
            key: MeetingHistoryResolver.historyKey(for: event),
            title: event.title,
            calendarTitle: event.calendarTitle,
            upcomingEvent: event
        )
    }

    static func meetingFamilyKnowledgeBaseCoverage(
        from contextPacks: [KBContextPack]
    ) -> MeetingFamilyKnowledgeBaseCoverage? {
        var bestDocumentsByPath: [String: MeetingFamilyKnowledgeBaseDocument] = [:]

        for pack in contextPacks {
            let key = (
                !pack.relativePath.isEmpty
                    ? pack.relativePath
                    : (!pack.documentTitle.isEmpty ? pack.documentTitle : pack.matchedText)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            guard !key.isEmpty else { continue }

            let document = MeetingFamilyKnowledgeBaseDocument(
                relativePath: pack.relativePath,
                title: Self.meetingFamilyKnowledgeBaseDocumentTitle(from: pack),
                score: pack.score
            )

            if let existing = bestDocumentsByPath[key], existing.score >= document.score {
                continue
            }
            bestDocumentsByPath[key] = document
        }

        let documents = bestDocumentsByPath.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        guard !documents.isEmpty else { return nil }

        return MeetingFamilyKnowledgeBaseCoverage(
            documentCount: documents.count,
            topDocuments: Array(documents.prefix(3))
        )
    }

    private static func meetingFamilyKnowledgeBaseDocumentTitle(from pack: KBContextPack) -> String {
        let title = pack.documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        let relativePath = pack.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !relativePath.isEmpty {
            return URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        }

        return "Untitled document"
    }

    static func notesPreview(from markdown: String) -> String? {
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("#") else { continue }
            guard !line.hasPrefix("!") else { continue }
            let sanitized = line
                .replacingOccurrences(
                    of: #"^([-*+]|[0-9]+\.)\s+"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty {
                return sanitized
            }
        }
        return nil
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
