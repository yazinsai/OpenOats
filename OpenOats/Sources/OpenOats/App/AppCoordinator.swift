import Foundation
import Observation
import SwiftUI

enum ExternalCommand: Equatable {
    case startSession
    case stopSession
    case openNotes(sessionID: String?)
}

struct ExternalCommandRequest: Identifiable, Equatable {
    let id: UUID
    let command: ExternalCommand

    init(command: ExternalCommand) {
        self.id = UUID()
        self.command = command
    }
}

/// Shared state coordinator injected into all window scenes.
/// Bridges the main window (transcription) and Notes window (history + generation).
@Observable
@MainActor
final class AppCoordinator {
    let sessionStore = SessionStore()
    let templateStore = TemplateStore()
    let notesEngine = NotesEngine()

    var selectedTemplate: MeetingTemplate?
    var lastEndedSession: SessionIndex?
    var pendingExternalCommand: ExternalCommandRequest?
    var requestedSessionSelectionID: String?
    private(set) var sessionHistory: [SessionIndex] = []

    /// The template snapshot frozen at session start (not stop).
    private var sessionTemplateSnapshot: TemplateSnapshot?

    /// Start a new recording session, optionally with a template.
    func startSession(transcriptStore: TranscriptStore) async {
        lastEndedSession = nil

        // Clear transcript from previous session
        transcriptStore.clear()

        // Freeze template choice at start time
        if let template = selectedTemplate {
            sessionTemplateSnapshot = templateStore.snapshot(of: template)
        } else if let generic = templateStore.template(for: TemplateStore.genericID) {
            sessionTemplateSnapshot = templateStore.snapshot(of: generic)
        } else {
            sessionTemplateSnapshot = nil
        }

        let templateID = selectedTemplate?.id
        await sessionStore.startSession(templateID: templateID)
    }

    /// Gracefully stop a session: drain audio, drain JSONL writes, write sidecar, close files.
    func finalizeSession(
        transcriptStore: TranscriptStore,
        transcriptionEngine: TranscriptionEngine?,
        transcriptLogger: TranscriptLogger?
    ) async {
        // 1. Drain audio buffers (flush final speech)
        await transcriptionEngine?.finalize()

        // 2. Drain delayed JSONL writes
        await sessionStore.awaitPendingWrites()

        // 3. Build sidecar from this session's transcript data
        let sessionID = await sessionStore.currentSessionID ?? "unknown"
        let utteranceCount = transcriptStore.utterances.count
        let title = transcriptStore.conversationState.currentTopic.isEmpty
            ? nil : transcriptStore.conversationState.currentTopic

        let index = SessionIndex(
            id: sessionID,
            startedAt: transcriptStore.utterances.first?.timestamp ?? Date(),
            endedAt: Date(),
            templateSnapshot: sessionTemplateSnapshot,
            title: title,
            utteranceCount: utteranceCount,
            hasNotes: false
        )
        let sidecar = SessionSidecar(index: index, notes: nil)

        // 4. Write sidecar
        await sessionStore.writeSidecar(sidecar)

        // 5. Close JSONL file
        await sessionStore.endSession()

        // 6. Close plain-text archive (after drain so final utterances are captured)
        await transcriptLogger?.endSession()

        // 7. Update UI state + refresh history so Notes window sees the new session
        lastEndedSession = index
        sessionTemplateSnapshot = nil
        await loadHistory()
    }

    /// Load session history from sidecars (lightweight index only).
    func loadHistory() async {
        sessionHistory = await sessionStore.loadSessionIndex()
    }

    func queueExternalCommand(_ command: ExternalCommand) {
        pendingExternalCommand = ExternalCommandRequest(command: command)
    }

    func completeExternalCommand(_ requestID: UUID) {
        guard pendingExternalCommand?.id == requestID else { return }
        pendingExternalCommand = nil
    }

    func queueSessionSelection(_ sessionID: String?) {
        requestedSessionSelectionID = sessionID
    }

    func consumeRequestedSessionSelection() -> String? {
        defer { requestedSessionSelectionID = nil }
        return requestedSessionSelectionID
    }
}
