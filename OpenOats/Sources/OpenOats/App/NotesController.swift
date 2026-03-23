import Foundation
import Observation

// MARK: - State

struct NotesState {
    var sessionHistory: [SessionIndex] = []
    var selectedSessionID: String?
    var loadedTranscript: [SessionRecord] = []
    var loadedNotes: EnhancedNotes?
    var notesGenerationStatus: GenerationStatus = .idle
    var cleanupStatus: CleanupStatus = .idle
    var selectedTemplate: MeetingTemplate?
    var showingOriginal: Bool = false
    /// Partial markdown streamed during generation.
    var streamingMarkdown: String = ""
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

        guard let sessionID else {
            state.loadedNotes = nil
            state.loadedTranscript = []
            return
        }

        state.loadedNotes = nil
        state.loadedTranscript = []
        state.showingOriginal = false
        coordinator.cleanupEngine.cancel()
        syncCleanupStatus()

        Task {
            let notes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
            let transcript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)

            guard state.selectedSessionID == sessionID else { return }

            state.loadedNotes = notes
            state.loadedTranscript = transcript

            let session = state.sessionHistory.first { $0.id == sessionID }
            if let snapID = session?.templateSnapshot?.id {
                state.selectedTemplate = coordinator.templateStore.template(for: snapID)
            } else {
                state.selectedTemplate = coordinator.templateStore.template(for: TemplateStore.genericID)
            }
        }
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
                let notes = EnhancedNotes(
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

    // MARK: - Transcript Cleanup

    func cleanUpTranscript(settings: AppSettings) {
        guard let sessionID = state.selectedSessionID, !state.loadedTranscript.isEmpty else { return }

        Task {
            let updated = await coordinator.cleanupEngine.cleanup(
                records: state.loadedTranscript,
                settings: settings
            )

            let utterances = updated.map { record in
                Utterance(
                    text: record.text,
                    speaker: record.speaker,
                    timestamp: record.timestamp,
                    refinedText: record.refinedText
                )
            }
            await coordinator.sessionRepository.backfillRefinedText(sessionID: sessionID, from: utterances)

            guard state.selectedSessionID == sessionID else { return }
            state.loadedTranscript = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
            syncCleanupStatus()
        }
    }

    func cancelCleanup() {
        coordinator.cleanupEngine.cancel()
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
        let engine = coordinator.cleanupEngine
        if engine.isCleaningUp {
            state.cleanupStatus = .inProgress(
                completed: engine.chunksCompleted,
                total: engine.totalChunks
            )
        } else if let error = engine.error {
            state.cleanupStatus = .error(error)
        } else if !state.loadedTranscript.isEmpty {
            let hasAny = state.loadedTranscript.contains { $0.refinedText != nil }
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
