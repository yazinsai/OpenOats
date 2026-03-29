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
        coordinator.batchTextCleaner.cancel()
        syncCleanupStatus()

        Task {
            let notes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
            let transcript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
            let audioURL = await coordinator.sessionRepository.audioFileURL(for: sessionID)

            guard state.selectedSessionID == sessionID else { return }

            state.loadedNotes = notes
            state.loadedTranscript = transcript
            state.audioFileURL = audioURL

            let session = state.sessionHistory.first { $0.id == sessionID }
            if let snapID = session?.templateSnapshot?.id {
                state.selectedTemplate = coordinator.templateStore.template(for: snapID)
            } else {
                state.selectedTemplate = coordinator.templateStore.template(for: TemplateStore.genericID)
            }
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

        state.notesGenerationStatus = .generating
        state.streamingMarkdown = ""

        Task {
            await coordinator.notesEngine.generate(
                transcript: state.loadedTranscript,
                template: template,
                settings: settings
            )

            if !coordinator.notesEngine.generatedMarkdown.isEmpty {
                let notes = GeneratedNotes(
                    template: coordinator.templateStore.snapshot(of: template),
                    generatedAt: Date(),
                    markdown: coordinator.notesEngine.generatedMarkdown
                )
                await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: notes)
                state.loadedNotes = notes

                await loadHistory()
                state.notesGenerationStatus = .completed
            } else if let error = coordinator.notesEngine.error {
                state.notesGenerationStatus = .error(error)
            } else {
                state.notesGenerationStatus = .idle
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

    func cancelGeneration() {
        coordinator.notesEngine.cancel()
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
            state.loadedTranscript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
            syncCleanupStatus()
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
            session.tags?.contains(where: { $0.localizedCaseInsensitiveCompare(filter) == .orderedSame }) ?? false
        }
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
        await coordinator.sessionRepository.allTags()
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

    // MARK: - Private

    func loadHistory() async {
        state.sessionHistory = await coordinator.sessionRepository.listSessions()
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
            state.cleanupStatus = .inProgress(
                completed: engine.chunksCompleted,
                total: engine.totalChunks
            )
        } else if let error = engine.error {
            state.cleanupStatus = .error(error)
        } else if !state.loadedTranscript.isEmpty {
            let hasAny = state.loadedTranscript.contains { $0.cleanedText != nil }
            if hasAny {
                state.cleanupStatus = .completed
            } else {
                state.cleanupStatus = .idle
            }
        } else {
            state.cleanupStatus = .idle
        }
    }

    private func syncGenerationStatus() {
        let engine = coordinator.notesEngine
        if engine.isGenerating {
            state.notesGenerationStatus = .generating
            state.streamingMarkdown = engine.generatedMarkdown
        }
        // Don't override .error or .completed set by generateNotes
    }
}
