import Foundation
import UniformTypeIdentifiers

// MARK: - Supporting Types

/// Lightweight metadata returned by `listSessions()`.
/// Mirrors `SessionIndex` but is produced from the canonical `session.json`.
typealias SessionIndexEntry = SessionIndex

/// Metadata needed to start a new session.
struct SessionStartConfig: Sendable {
    let templateID: UUID?
    let templateSnapshot: TemplateSnapshot?
    let title: String?
    let calendarEvent: CalendarEvent?

    init(
        templateID: UUID? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        calendarEvent: CalendarEvent? = nil
    ) {
        self.templateID = templateID
        self.templateSnapshot = templateSnapshot
        self.title = title
        self.calendarEvent = calendarEvent
    }
}

/// Handle returned by `startSession` — callers use `sessionID` to address
/// subsequent writes.
struct SessionHandle: Sendable {
    let sessionID: String
}

/// Metadata attached to each live utterance write.
struct LiveUtteranceMetadata: Sendable {
    let utteranceID: UUID?
    let suggestionEngine: SuggestionEngine?
    let transcriptStore: TranscriptStore?
    let isDelayed: Bool

    init(
        utteranceID: UUID? = nil,
        suggestionEngine: SuggestionEngine? = nil,
        transcriptStore: TranscriptStore? = nil,
        isDelayed: Bool = false
    ) {
        self.utteranceID = utteranceID
        self.suggestionEngine = suggestionEngine
        self.transcriptStore = transcriptStore
        self.isDelayed = isDelayed
    }
}

/// Metadata collected at finalization time.
struct SessionFinalizeMetadata: Sendable {
    let endedAt: Date
    let utteranceCount: Int
    let title: String?
    let language: String?
    let meetingApp: String?
    let engine: String?
    let templateSnapshot: TemplateSnapshot?
    let utterances: [Utterance]
    let calendarEvent: CalendarEvent?
    let transcriptIssue: SessionTranscriptIssue?

    init(
        endedAt: Date,
        utteranceCount: Int,
        title: String?,
        language: String?,
        meetingApp: String?,
        engine: String?,
        templateSnapshot: TemplateSnapshot?,
        utterances: [Utterance],
        calendarEvent: CalendarEvent? = nil,
        transcriptIssue: SessionTranscriptIssue? = nil
    ) {
        self.endedAt = endedAt
        self.utteranceCount = utteranceCount
        self.title = title
        self.language = language
        self.meetingApp = meetingApp
        self.engine = engine
        self.templateSnapshot = templateSnapshot
        self.utterances = utterances
        self.calendarEvent = calendarEvent
        self.transcriptIssue = transcriptIssue
    }
}

struct ManualTranscriptSessionConfig: Sendable {
    let title: String
    let startedAt: Date
    let endedAt: Date
    let calendarEvent: CalendarEvent
    let folderPath: String?
}

/// Full session detail for loading.
struct SessionDetail: Sendable {
    let index: SessionIndex
    let transcript: [SessionRecord]
    let liveTranscript: [SessionRecord]
    let notes: GeneratedNotes?
    let notesMeta: NotesMeta?
    let attachments: [NoteAttachment]
    let calendarEvent: CalendarEvent?

    init(
        index: SessionIndex,
        transcript: [SessionRecord],
        liveTranscript: [SessionRecord],
        notes: GeneratedNotes?,
        notesMeta: NotesMeta?,
        attachments: [NoteAttachment] = [],
        calendarEvent: CalendarEvent? = nil
    ) {
        self.index = index
        self.transcript = transcript
        self.liveTranscript = liveTranscript
        self.notes = notes
        self.notesMeta = notesMeta
        self.attachments = attachments
        self.calendarEvent = calendarEvent
    }
}

/// Metadata persisted alongside notes.
struct NotesMeta: Codable, Sendable {
    let templateSnapshot: TemplateSnapshot
    let generatedAt: Date
    let attachments: [NoteAttachment]?
}

// MARK: - Canonical session.json

/// The metadata file stored at `sessions/<id>/session.json`.
struct SessionMetadata: Codable, Sendable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var templateSnapshot: TemplateSnapshot?
    var title: String?
    var utteranceCount: Int
    var hasNotes: Bool
    var language: String?
    var meetingApp: String?
    var engine: String?
    var tags: [String]?
    var folderPath: String? = nil
    /// How the session was created (nil for live sessions, "imported" for imported audio).
    var source: String?
    var calendarEvent: CalendarEvent?
    var transcriptIssue: SessionTranscriptIssue?
    var transcriptRecovery: SessionTranscriptRecoveryState? = nil
    var customNotesGuidance: String?
    /// Per-session custom speaker display names. Keys are Speaker.storageKey values.
    var speakerNames: [String: String]?
    /// Set when the most recent notes-folder mirror failed (e.g. the folder is
    /// on an unreachable network mount) so the export can be retried later.
    var mirrorPending: Bool? = nil
}

// MARK: - SessionRepository

/// Unified storage actor replacing SessionStore + TranscriptLogger.
///
/// Canonical layout per session:
/// ```
/// sessions/<id>/session.json
/// sessions/<id>/transcript.live.jsonl
/// sessions/<id>/transcript.final.jsonl
/// sessions/<id>/notes.md
/// sessions/<id>/notes.meta.json
/// sessions/<id>/attachments/
/// sessions/<id>/audio/
/// ```
actor SessionRepository {
    /// Default retention for batch stems/metadata: long enough to support true reruns and debugging.
    static let retainedBatchAudioLifetime: TimeInterval = 7 * 24 * 3600

    /// How often the running app re-checks retained batch audio for expiry.
    /// The init-time sweep alone is not enough for a menu-bar app that stays up for weeks.
    static let retainedBatchAudioSweepInterval: TimeInterval = 6 * 3600

    /// Returns the current retention window in seconds (`nil` = keep forever).
    /// Re-read on every sweep so setting changes apply without a relaunch.
    private let batchAudioRetention: @Sendable () -> TimeInterval?

    /// Repeating background sweep started in `init`, cancelled in `deinit`.
    private var retainedAudioSweepTask: Task<Void, Never>?

    /// Sessions whose retained audio is currently being read by a batch run,
    /// with a count so overlapping runs for the same session keep the guard up.
    private var activeBatchAudioAccessCounts: [String: Int] = [:]

    /// Invoked with the affected session IDs after a sweep removes retained audio.
    private var onRetainedAudioSwept: (@Sendable ([String]) -> Void)?

    private let sessionsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Live Session State

    private var currentSessionID: String?
    private var liveFileHandle: FileHandle?
    private var liveUtteranceCount: Int = 0

    /// Tracks in-flight delayed writes.
    private var pendingWrites = 0
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called (once) when a write error occurs during the session.
    private var onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    /// User-facing notes folder for mirroring (e.g. ~/Documents/OpenOats).
    private var notesFolderPath: URL?
    private var meetingTranscriptDateFolderFormat: MeetingTranscriptDateFolderFormat?

    /// Whether `notesFolderPath` is a security-scoped URL that requires
    /// `startAccessingSecurityScopedResource()` before file I/O.
    private var notesFolderIsSecurityScoped = false

    /// Bounds retry work for notes-folder mirrors that keep failing (e.g. an
    /// unreachable network mount). Tracks the sessions whose most recent mirror
    /// failed, mirroring the durable `SessionMetadata.mirrorPending` flags.
    private var mirrorAttempts: MirrorAttemptLedger

    /// Default minimum interval between retries of a failed mirror.
    static let defaultMirrorRetryBackoff: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - mirrorRetryBackoff: Minimum interval between retries of a session
    ///     whose notes-folder mirror failed. Lowered by tests.
    ///   - batchAudioRetention: How long retained batch audio lives. `nil`
    ///     keeps it forever.
    init(
        rootDirectory: URL? = nil,
        mirrorRetryBackoff: TimeInterval = SessionRepository.defaultMirrorRetryBackoff,
        // Fail closed: deleting audio is destructive, so a constructor path that
        // does not wire the retention setting (tests, UI-test bootstrap, future
        // call sites) must keep forever, never silently become a deleter.
        batchAudioRetention: @escaping @Sendable () -> TimeInterval? = { nil }
    ) {
        self.batchAudioRetention = batchAudioRetention

        let baseDirectory: URL
        if let rootDirectory {
            baseDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            baseDirectory = appSupport.appendingPathComponent("OpenOats", isDirectory: true)
        }
        sessionsDirectory = baseDirectory.appendingPathComponent("sessions", isDirectory: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        mirrorAttempts = MirrorAttemptLedger(retryBackoff: mirrorRetryBackoff)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: sessionsDirectory)

        Self.cleanupExpiredRetainedBatchAudio(in: sessionsDirectory, olderThan: batchAudioRetention())

        Task { await self.restorePendingMirrors() }
        Task { [weak self] in await self?.startPeriodicRetainedBatchAudioSweeps() }
    }

    deinit {
        retainedAudioSweepTask?.cancel()
    }

    private func startPeriodicRetainedBatchAudioSweeps() {
        guard retainedAudioSweepTask == nil else { return }
        retainedAudioSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.retainedBatchAudioSweepInterval))
                guard !Task.isCancelled, let self else { break }
                await self.sweepExpiredRetainedBatchAudio()
            }
        }
    }

    // MARK: - Configuration

    /// Update the notes folder path used for mirroring artifacts.
    /// - Parameters:
    ///   - url: The folder URL (may be a security-scoped URL resolved from a bookmark).
    ///   - securityScoped: Pass `true` when the URL was resolved from a security-scoped bookmark.
    func setNotesFolderPath(
        _ url: URL?,
        securityScoped: Bool = false,
        dateSubfolderFormat: MeetingTranscriptDateFolderFormat? = nil
    ) {
        // startTranscription re-applies the same folder at every recording
        // start. Only a genuinely new destination is evidence that a previously
        // failed mirror can now succeed, so the failure backoff is kept
        // otherwise — that is what stops a dead mount from being re-driven once
        // per recording. A new destination also invalidates whatever attempts
        // are running against the old one.
        let destinationChanged = url != notesFolderPath
        notesFolderPath = url
        notesFolderIsSecurityScoped = securityScoped
        meetingTranscriptDateFolderFormat = dateSubfolderFormat
        if destinationChanged {
            mirrorAttempts.destinationChanged()
        }
        retryPendingMirrors()
    }

    /// Register a callback invoked once per session when a write error occurs.
    func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
    }

    /// Register a callback invoked with the affected session IDs after a sweep
    /// removes retained batch audio, so dependent UI state can re-derive.
    func setRetainedAudioSweepHandler(_ handler: @escaping @Sendable ([String]) -> Void) {
        onRetainedAudioSwept = handler
    }

    // MARK: - Session Lifecycle

    @discardableResult
    func startSession(config: SessionStartConfig = SessionStartConfig()) -> SessionHandle {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: Date()))"
        currentSessionID = sessionID
        hasReportedWriteError = false
        liveUtteranceCount = 0

        let sessionDir = sessionDirectory(for: sessionID)
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        openLiveTranscriptFileHandle(sessionID: sessionID)

        // Write initial session.json
        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: Date(),
            templateSnapshot: config.templateSnapshot,
            title: config.title,
            utteranceCount: 0,
            hasNotes: false,
            calendarEvent: config.calendarEvent,
            transcriptRecovery: nil
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return SessionHandle(sessionID: sessionID)
    }

    @discardableResult
    func resumeAbandonedSession(
        config: SessionStartConfig,
        maximumGap: TimeInterval = 6 * 60 * 60
    ) -> SessionHandle? {
        guard let sessionID = resumableSessionID(config: config, maximumGap: maximumGap) else {
            return nil
        }

        currentSessionID = sessionID
        hasReportedWriteError = false
        liveUtteranceCount = 0
        openLiveTranscriptFileHandle(sessionID: sessionID)

        if var metadata = loadSessionMetadataFile(sessionID: sessionID) {
            metadata.templateSnapshot = config.templateSnapshot ?? metadata.templateSnapshot
            if let title = config.title {
                metadata.title = title
            }
            if let calendarEvent = config.calendarEvent {
                metadata.calendarEvent = calendarEvent
            }
            writeSessionMetadata(metadata, sessionID: sessionID)
        }

        return SessionHandle(sessionID: sessionID)
    }

    // MARK: - Live Utterance Writing

    /// Append a live utterance to transcript.live.jsonl.
    /// For remote speakers with `isDelayed`, uses delayed-write aggregation.
    func appendLiveUtterance(
        sessionID: String,
        utterance: Utterance,
        metadata: LiveUtteranceMetadata = LiveUtteranceMetadata()
    ) {
        let baseRecord = SessionRecord(
            speaker: utterance.speaker,
            text: utterance.text,
            timestamp: utterance.timestamp,
            cleanedText: utterance.cleanedText
        )

        if metadata.isDelayed {
            appendRecordDelayed(
                baseRecord: baseRecord,
                utteranceID: metadata.utteranceID,
                suggestionEngine: metadata.suggestionEngine,
                transcriptStore: metadata.transcriptStore
            )
        } else {
            appendRecord(baseRecord)
        }
    }

    /// Direct record append (for local speaker / non-delayed writes).
    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle = liveFileHandle else {
            reportWriteError("No file handle available for session write")
            return
        }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
            liveUtteranceCount += 1
        } catch {
            reportWriteError("Failed to write record: \(error.localizedDescription)")
        }
    }

    /// Delayed write: sleeps 5s to capture pipeline enrichment, then writes.
    private func appendRecordDelayed(
        baseRecord: SessionRecord,
        utteranceID: UUID?,
        suggestionEngine: SuggestionEngine?,
        transcriptStore: TranscriptStore?
    ) {
        pendingWrites += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))

            guard let self else { return }

            let snapshot: SuggestionEngine.LogSnapshot?
            if let utteranceID {
                snapshot = await suggestionEngine?.logSnapshot(forTriggerUtteranceID: utteranceID)
            } else {
                snapshot = nil
            }
            let summary = await transcriptStore?.conversationState.shortSummary

            let cleanedText: String?
            if let utteranceID, let store = transcriptStore {
                cleanedText = await store.utterances.first(where: { $0.id == utteranceID })?.cleanedText
            } else {
                cleanedText = baseRecord.cleanedText
            }

            let enrichedRecord = SessionRecord(
                speaker: baseRecord.speaker,
                text: baseRecord.text,
                timestamp: baseRecord.timestamp,
                suggestions: snapshot.map { [$0.surfacedText] },
                kbHits: snapshot?.kbHitPaths,
                suggestionDecision: nil,
                surfacedSuggestionText: snapshot?.surfacedText,
                conversationStateSummary: summary?.isEmpty == false ? summary : nil,
                cleanedText: cleanedText,
                suggestionID: snapshot?.suggestionID,
                triggerUtteranceID: snapshot?.triggerUtteranceID,
                suggestionLifecycle: snapshot?.lifecycle
            )

            await self.appendRecord(enrichedRecord)
            await self.decrementPendingWrites()
        }
    }

    private func decrementPendingWrites() {
        pendingWrites -= 1
        if pendingWrites == 0 {
            let waiters = pendingWriteWaiters
            pendingWriteWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Suspends until all in-flight delayed writes have completed.
    func awaitPendingWrites() async {
        guard pendingWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            pendingWriteWaiters.append(continuation)
        }
    }

    // MARK: - Finalization

    func finalizeSession(sessionID: String, metadata: SessionFinalizeMetadata) {
        // Close the live file handle
        try? liveFileHandle?.close()
        liveFileHandle = nil
        currentSessionID = nil

        // Backfill cleaned text into live transcript
        backfillCleanedText(sessionID: sessionID, from: metadata.utterances)

        let existingMetadata = loadSessionMetadataFile(sessionID: sessionID)
        let startedAt = metadata.utterances.first?.timestamp
            ?? existingMetadata?.startedAt
            ?? Date()

        // Names the user set by hand always win; otherwise take them from the
        // calendar event, which only happens when the mapping is unambiguous.
        let speakerNames = existingMetadata?.speakerNames ?? {
            guard let event = metadata.calendarEvent else { return nil }
            let seeded = SpeakerNameSeeder.seededNames(
                remoteSpeakerKeys: SpeakerNameSeeder.remoteSpeakerKeys(in: metadata.utterances),
                participantNames: event.invitedParticipantDisplayNames,
                recorderName: NSFullUserName()
            )
            return seeded.isEmpty ? nil : seeded
        }()

        // Write session.json with final metadata
        let sessionMeta = SessionMetadata(
            id: sessionID,
            startedAt: startedAt,
            endedAt: metadata.endedAt,
            templateSnapshot: metadata.templateSnapshot,
            title: metadata.title,
            utteranceCount: metadata.utteranceCount,
            hasNotes: false,
            language: metadata.language,
            meetingApp: metadata.meetingApp,
            engine: metadata.engine,
            calendarEvent: metadata.calendarEvent,
            transcriptIssue: metadata.transcriptIssue,
            transcriptRecovery: nil,
            speakerNames: speakerNames,
            // Hand-built metadata: carry the durable mirror flag across, or a
            // pending export is lost the moment the session is finalized.
            mirrorPending: existingMetadata?.mirrorPending
        )
        writeSessionMetadata(sessionMeta, sessionID: sessionID)

        scheduleMirror(sessionID: sessionID)
    }

    /// End a session without full finalization (discard path).
    func endSession() {
        try? liveFileHandle?.close()
        liveFileHandle = nil
        currentSessionID = nil
        liveUtteranceCount = 0
    }

    // MARK: - Imported Session

    /// Configuration for creating an imported session (no live file handle needed).
    struct ImportedSessionConfig: Sendable {
        let title: String
        let startedAt: Date
        let endedAt: Date
        let language: String?
        let engine: String?
    }

    /// Create a session directory and initial metadata for an imported audio file.
    /// Unlike `startSession`, this does not open a live file handle.
    @discardableResult
    func createImportedSession(config: ImportedSessionConfig) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: config.startedAt))"

        let sessionDir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Create audio subdirectory
        let audioDir = sessionDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: config.startedAt,
            endedAt: config.endedAt,
            title: config.title,
            utteranceCount: 0,
            hasNotes: false,
            language: config.language,
            engine: config.engine,
            source: "imported",
            transcriptRecovery: nil
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return sessionID
    }

    @discardableResult
    func createManualTranscriptSession(config: ManualTranscriptSessionConfig) -> String {
        if let existingSessionID = existingSessionID(for: config.calendarEvent, referenceDate: config.startedAt) {
            return existingSessionID
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: config.startedAt))"

        let sessionDir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: config.startedAt,
            endedAt: config.endedAt,
            title: config.title,
            utteranceCount: 0,
            hasNotes: false,
            folderPath: Self.normalizeSessionFolderPath(config.folderPath),
            source: "manual",
            calendarEvent: config.calendarEvent,
            transcriptRecovery: nil
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

        return sessionID
    }

    /// Update utterance count and endedAt for a finalized imported session.
    func finalizeImportedSession(sessionID: String, utteranceCount: Int, endedAt: Date) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.utteranceCount = utteranceCount
        meta.endedAt = endedAt
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Copy an audio file into the session's audio directory.
    func copyAudioFileToSession(sessionID: String, sourceURL: URL) {
        let audioDir = sessionDirectory(for: sessionID)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let dest = audioDir.appendingPathComponent("imported.\(sourceURL.pathExtension)")
        try? FileManager.default.copyItem(at: sourceURL, to: dest)
    }

    // MARK: - Final Transcript

    func saveFinalTranscript(
        sessionID: String,
        records: [SessionRecord],
        backupCurrentTranscript: Bool = false,
        markAsRecoveredIfIssuePresent: Bool = false
    ) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if backupCurrentTranscript {
            backupTranscriptForBatchOverwrite(sessionID: sessionID)
        }

        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(Data("\n".utf8))
            }
        }

        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        let tempURL = dir.appendingPathComponent("transcript.final.jsonl.tmp")

        do {
            try payload.write(to: tempURL, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            Log.sessionRepository.error("Failed to write final transcript: \(error, privacy: .public)")
        }

        if let meta = loadSessionMetadataFile(sessionID: sessionID) {
            let transcriptRecovery: SessionTranscriptRecoveryState?
            if markAsRecoveredIfIssuePresent, meta.transcriptIssue != nil {
                transcriptRecovery = .recoveredAfterBatch
            } else {
                transcriptRecovery = nil
            }
            let refreshedMeta = SessionMetadata(
                id: meta.id,
                startedAt: records.first?.timestamp ?? meta.startedAt,
                endedAt: records.last?.timestamp ?? meta.endedAt,
                templateSnapshot: meta.templateSnapshot,
                title: meta.title,
                utteranceCount: records.count,
                hasNotes: meta.hasNotes,
                language: meta.language,
                meetingApp: meta.meetingApp,
                engine: meta.engine,
                tags: meta.tags,
                folderPath: meta.folderPath,
                source: meta.source,
                calendarEvent: meta.calendarEvent,
                transcriptIssue: nil,
                transcriptRecovery: transcriptRecovery,
                mirrorPending: meta.mirrorPending
            )
            writeSessionMetadata(refreshedMeta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath
        scheduleMirror(sessionID: sessionID)
    }

    func saveManualTranscriptSource(sessionID: String, text: String) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.manual.txt")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }

        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    func loadManualTranscriptSource(sessionID: String) -> String? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("transcript.manual.txt")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func backupTranscriptForBatchOverwrite(sessionID: String) {
        let dir = sessionDirectory(for: sessionID)
        let fm = FileManager.default
        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        let backupURL = dir.appendingPathComponent("transcript.pre-batch.jsonl")

        let sourceURL: URL?
        if fm.fileExists(atPath: finalURL.path), let data = try? Data(contentsOf: finalURL), !data.isEmpty {
            sourceURL = finalURL
        } else if fm.fileExists(atPath: liveURL.path), let data = try? Data(contentsOf: liveURL), !data.isEmpty {
            sourceURL = liveURL
        } else {
            sourceURL = nil
        }

        guard let sourceURL else { return }

        try? fm.removeItem(at: backupURL)
        do {
            try fm.copyItem(at: sourceURL, to: backupURL)
        } catch {
            Log.sessionRepository.error("Failed to back up transcript before batch overwrite: \(error, privacy: .public)")
        }
    }

    // MARK: - Notes

    func saveNotes(sessionID: String, notes: GeneratedNotes) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write notes.md
        let mdURL = dir.appendingPathComponent("notes.md")
        try? notes.markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        // Write notes.meta.json
        let existingAttachments = loadNotesMeta(sessionID: sessionID)?.attachments
        let meta = NotesMeta(
            templateSnapshot: notes.template,
            generatedAt: notes.generatedAt,
            attachments: existingAttachments
        )
        saveNotesMeta(meta, sessionID: sessionID)

        // Update session.json hasNotes flag
        if var sessionMeta = loadSessionMetadataFile(sessionID: sessionID) {
            sessionMeta.hasNotes = true
            writeSessionMetadata(sessionMeta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath — pass markdown through to avoid re-reading from disk
        scheduleMirror(sessionID: sessionID, notesMarkdown: notes.markdown)
    }

    /// Result of a generated-notes write that had to inspect the session first.
    enum GeneratedNotesWriteOutcome: Sendable, Equatable {
        case written
        /// The session was deleted before the write.
        case sessionMissing
        /// The session gained notes before the write.
        case notesAlreadyExist
    }

    /// Write generated notes, but only while the session still exists and
    /// still has no notes.
    ///
    /// Generation takes minutes, so the session can change underneath it: the
    /// user may delete the meeting, or write notes by hand. A caller cannot
    /// guard that itself, because every call into this actor is a suspension
    /// point — a delete or a manual save can land between a caller's check and
    /// its write, which resurrects a deleted session as an empty shell or
    /// overwrites the user's own notes. The check and the write therefore
    /// happen here, in one operation, with no suspension between them.
    ///
    /// The heading needs the session's current title and start date, so
    /// normalization happens here too rather than against a stale read.
    func saveGeneratedNotesIfAbsent(
        sessionID: String,
        template: TemplateSnapshot,
        markdown: String,
        generatedAt: Date
    ) -> GeneratedNotesWriteOutcome {
        guard sessionExists(id: sessionID) else { return .sessionMissing }

        let session = loadSession(id: sessionID).index
        guard !session.hasNotes else { return .notesAlreadyExist }

        let notes = GeneratedNotes(
            template: template,
            generatedAt: generatedAt,
            markdown: GeneratedNotes.normalizedMarkdown(
                markdown,
                title: session.title,
                date: session.startedAt
            )
        )
        saveNotes(sessionID: sessionID, notes: notes)
        return .written
    }

    func loadNotes(sessionID: String) -> GeneratedNotes? {
        let dir = sessionDirectory(for: sessionID)
        let mdURL = dir.appendingPathComponent("notes.md")
        guard let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
              let meta = loadNotesMeta(sessionID: sessionID) else {
            // Fall back to legacy
            return LegacySessionReader.loadNotes(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        }

        return GeneratedNotes(
            template: meta.templateSnapshot,
            generatedAt: meta.generatedAt,
            markdown: markdown
        )
    }

    func importAttachment(sessionID: String, sourceURL: URL) -> NoteAttachment? {
        let dir = attachmentsDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sanitizedBaseName = Self.sanitizedAttachmentFilename(sourceURL.deletingPathExtension().lastPathComponent)
        let pathExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedFilename: String
        if pathExtension.isEmpty {
            storedFilename = "\(UUID().uuidString)-\(sanitizedBaseName)"
        } else {
            storedFilename = "\(UUID().uuidString)-\(sanitizedBaseName).\(pathExtension)"
        }

        let destinationURL = dir.appendingPathComponent(storedFilename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            Log.sessionRepository.error("Failed to import attachment: \(error, privacy: .public)")
            return nil
        }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)

        let resourceValues = try? destinationURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let contentType = resourceValues?.contentType?.identifier
            ?? UTType(filenameExtension: destinationURL.pathExtension)?.identifier
        let byteSize = Int64(resourceValues?.fileSize ?? 0)
        let attachment = NoteAttachment(
            displayName: sourceURL.lastPathComponent,
            relativePath: "attachments/\(storedFilename)",
            contentType: contentType,
            byteSize: byteSize,
            createdAt: Date()
        )

        let existingMeta = loadNotesMeta(sessionID: sessionID)
        let attachments = (existingMeta?.attachments ?? []) + [attachment]
        let fallbackTemplate = existingMeta?.templateSnapshot
            ?? TemplateSnapshot(
                id: UUID(),
                name: "Generic",
                icon: "doc.text",
                systemPrompt: ""
            )
        let fallbackGeneratedAt = existingMeta?.generatedAt ?? Date()
        let updatedMeta = NotesMeta(
            templateSnapshot: fallbackTemplate,
            generatedAt: fallbackGeneratedAt,
            attachments: attachments
        )
        saveNotesMeta(updatedMeta, sessionID: sessionID)
        return attachment
    }

    func loadNoteAttachments(sessionID: String) -> [NoteAttachment] {
        (loadNotesMeta(sessionID: sessionID)?.attachments ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Custom Notes Guidance

    func loadCustomNotesGuidance(sessionID: String) -> String? {
        loadSessionMetadataFile(sessionID: sessionID)?.customNotesGuidance
    }

    func saveCustomNotesGuidance(sessionID: String, guidance: String?) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.customNotesGuidance = guidance
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    // MARK: - Scratchpad

    /// Save the user's live scratchpad notes for a session.
    func saveScratchpad(sessionID: String, text: String) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scratchpad.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Load the user's scratchpad for a session (returns empty string if none).
    func loadScratchpad(sessionID: String) -> String {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("scratchpad.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Images

    func saveImage(sessionID: String, imageData: Data) -> String {
        let dir = sessionDirectory(for: sessionID)
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).png"
        let url = dir.appendingPathComponent(filename)
        try? imageData.write(to: url, options: .atomic)
        return filename
    }

    // MARK: - Listing & Loading

    func listSessions() -> [SessionIndex] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [SessionIndex] = []

        // Canonical sessions: directories with session.json
        for item in contents {
            let name = item.lastPathComponent
            // Skip hidden directories and non-session items
            guard !name.hasPrefix(".") else { continue }

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let metaURL = item.appendingPathComponent("session.json")
                if let data = try? Data(contentsOf: metaURL),
                   let meta = try? decoder.decode(SessionMetadata.self, from: data) {
                    results.append(SessionIndex(
                        id: meta.id,
                        startedAt: meta.startedAt,
                        endedAt: meta.endedAt,
                        templateSnapshot: meta.templateSnapshot,
                        title: meta.title,
                        utteranceCount: meta.utteranceCount,
                        hasNotes: meta.hasNotes,
                        language: meta.language,
                        meetingApp: meta.meetingApp,
                        engine: meta.engine,
                        tags: meta.tags,
                        folderPath: meta.folderPath,
                        source: meta.source,
                        meetingFamilyKey: meta.calendarEvent.flatMap { MeetingHistoryResolver.seriesHistoryKey(for: $0) },
                        transcriptIssue: meta.transcriptIssue,
                        transcriptRecovery: meta.transcriptRecovery,
                        speakerNames: meta.speakerNames
                    ))
                    continue
                }
            }
        }

        // Legacy sessions: .jsonl files without canonical directories
        let canonicalIDs = Set(results.map(\.id))
        let legacyResults = LegacySessionReader.listSessions(
            sessionsDirectory: sessionsDirectory,
            excludingIDs: canonicalIDs
        )
        results.append(contentsOf: legacyResults)

        return results.sorted { $0.startedAt > $1.startedAt }
    }

    /// True when the session still has a record on disk.
    ///
    /// Writers check this before saving into a session directory: `saveNotes`
    /// creates the directory it writes to, so a save that lands after the user
    /// deleted the meeting would resurrect it as an empty shell.
    func sessionExists(id: String) -> Bool {
        let fm = FileManager.default
        let canonical = sessionDirectory(for: id).appendingPathComponent("session.json")
        if fm.fileExists(atPath: canonical.path) { return true }
        // Legacy layout: <sessions>/<id>.jsonl beside an optional sidecar.
        return fm.fileExists(atPath: sessionsDirectory.appendingPathComponent("\(id).jsonl").path)
    }

    func loadSession(id: String) -> SessionDetail {
        let dir = sessionDirectory(for: id)
        let metaURL = dir.appendingPathComponent("session.json")

        // Try canonical first
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(SessionMetadata.self, from: data) {
            let index = SessionIndex(
                id: meta.id,
                startedAt: meta.startedAt,
                endedAt: meta.endedAt,
                templateSnapshot: meta.templateSnapshot,
                title: meta.title,
                utteranceCount: meta.utteranceCount,
                hasNotes: meta.hasNotes,
                language: meta.language,
                meetingApp: meta.meetingApp,
                engine: meta.engine,
                tags: meta.tags,
                folderPath: meta.folderPath,
                source: meta.source,
                meetingFamilyKey: meta.calendarEvent.flatMap { MeetingHistoryResolver.seriesHistoryKey(for: $0) },
                transcriptIssue: meta.transcriptIssue,
                transcriptRecovery: meta.transcriptRecovery,
                speakerNames: meta.speakerNames
            )

            let transcript = loadTranscript(sessionID: id)
            let liveTranscript = loadLiveTranscript(sessionID: id)
            let notes = loadNotes(sessionID: id)
            let notesMeta = loadNotesMeta(sessionID: id)

            return SessionDetail(
                index: index,
                transcript: transcript,
                liveTranscript: liveTranscript,
                notes: notes,
                notesMeta: notesMeta,
                attachments: notesMeta?.attachments ?? [],
                calendarEvent: meta.calendarEvent
            )
        }

        // Fall back to legacy
        return LegacySessionReader.loadSession(id: id, sessionsDirectory: sessionsDirectory)
    }

    func loadTranscript(sessionID: String) -> [SessionRecord] {
        let dir = sessionDirectory(for: sessionID)

        // Prefer final transcript
        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        if FileManager.default.fileExists(atPath: finalURL.path),
           let content = try? String(contentsOf: finalURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Then live transcript
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if FileManager.default.fileExists(atPath: liveURL.path),
           let content = try? String(contentsOf: liveURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Fall back to legacy
        return LegacySessionReader.loadTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    func loadLiveTranscript(sessionID: String) -> [SessionRecord] {
        let dir = sessionDirectory(for: sessionID)
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if let content = try? String(contentsOf: liveURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Fall back to legacy live transcript
        return LegacySessionReader.loadLiveTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    // MARK: - Session Management

    func renameSession(sessionID: String, title: String) {
        // Try canonical
        if var meta = loadSessionMetadataFile(sessionID: sessionID) {
            meta.title = title.isEmpty ? nil : title
            writeSessionMetadata(meta, sessionID: sessionID)
            scheduleMirror(sessionID: sessionID)
            return
        }

        // Fall back to legacy rename (updates sidecar)
        LegacySessionReader.renameSession(
            sessionID: sessionID,
            newTitle: title,
            sessionsDirectory: sessionsDirectory
        )
    }

    func updateSessionTags(sessionID: String, tags: [String]) {
        let normalizedVisibleTags = Self.normalizeUserVisibleTags(tags)

        // Try canonical first
        if var meta = loadSessionMetadataFile(sessionID: sessionID) {
            let preservedInternalTags = Self.internalSessionTags(from: meta.tags ?? [])
            let combinedTags = preservedInternalTags + normalizedVisibleTags
            meta.tags = combinedTags.isEmpty ? nil : combinedTags
            writeSessionMetadata(meta, sessionID: sessionID)
            return
        }

        // For legacy sessions: migrate to canonical format on first tag write
        let index = LegacySessionReader.loadIndex(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        let meta = SessionMetadata(
            id: index.id,
            startedAt: index.startedAt,
            endedAt: index.endedAt,
            templateSnapshot: index.templateSnapshot,
            title: index.title,
            utteranceCount: index.utteranceCount,
            hasNotes: index.hasNotes,
            language: index.language,
            meetingApp: index.meetingApp,
            engine: index.engine,
            tags: normalizedVisibleTags.isEmpty ? nil : normalizedVisibleTags,
            folderPath: index.folderPath,
            source: index.source,
            transcriptRecovery: nil
        )
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    func updateSessionFolder(sessionID: String, folderPath: String?) {
        let normalizedFolderPath = Self.normalizeSessionFolderPath(folderPath)

        if var meta = loadSessionMetadataFile(sessionID: sessionID) {
            meta.folderPath = normalizedFolderPath
            writeSessionMetadata(meta, sessionID: sessionID)
            return
        }

        let index = LegacySessionReader.loadIndex(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        let meta = SessionMetadata(
            id: index.id,
            startedAt: index.startedAt,
            endedAt: index.endedAt,
            templateSnapshot: index.templateSnapshot,
            title: index.title,
            utteranceCount: index.utteranceCount,
            hasNotes: index.hasNotes,
            language: index.language,
            meetingApp: index.meetingApp,
            engine: index.engine,
            tags: index.tags,
            folderPath: normalizedFolderPath,
            source: index.source,
            transcriptRecovery: nil
        )
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    func updateSessionSpeakerNames(sessionID: String, speakerNames: [String: String]) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.speakerNames = speakerNames.isEmpty ? nil : speakerNames
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    func updateSessionCalendarEvent(sessionID: String, calendarEvent: CalendarEvent?) {
        if var meta = loadSessionMetadataFile(sessionID: sessionID) {
            meta.calendarEvent = calendarEvent
            writeSessionMetadata(meta, sessionID: sessionID)
            scheduleMirror(sessionID: sessionID)
            return
        }

        let index = LegacySessionReader.loadIndex(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        let meta = SessionMetadata(
            id: index.id,
            startedAt: index.startedAt,
            endedAt: index.endedAt,
            templateSnapshot: index.templateSnapshot,
            title: index.title,
            utteranceCount: index.utteranceCount,
            hasNotes: index.hasNotes,
            language: index.language,
            meetingApp: index.meetingApp,
            engine: index.engine,
            tags: index.tags,
            folderPath: index.folderPath,
            source: index.source,
            calendarEvent: calendarEvent,
            transcriptRecovery: nil
        )
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeSessionMetadata(meta, sessionID: sessionID)
        scheduleMirror(sessionID: sessionID)
    }

    func reconcileGhostSession(
        sessionID: String,
        maximumGap: TimeInterval = 5 * 60
    ) -> String? {
        guard let ghostMeta = loadSessionMetadataFile(sessionID: sessionID),
              ghostMeta.utteranceCount == 0,
              ghostMeta.hasNotes == false,
              let calendarEvent = ghostMeta.calendarEvent,
              !sessionHasMeaningfulArtifacts(sessionID: sessionID) else { return nil }

        let historyKey = MeetingHistoryResolver.historyKey(for: ghostMeta.title ?? calendarEvent.title)
        guard !historyKey.isEmpty else { return nil }

        let candidates = listSessions()
            .filter { candidate in
                guard candidate.id != sessionID else { return false }
                guard candidate.utteranceCount > 0 else { return false }
                guard MeetingHistoryResolver.historyKey(for: candidate.title ?? "") == historyKey else {
                    return false
                }
                let referenceDate = candidate.endedAt ?? candidate.startedAt
                let gap = ghostMeta.startedAt.timeIntervalSince(referenceDate)
                return gap >= 0 && gap <= maximumGap
            }
            .sorted {
                let lhsGap = ghostMeta.startedAt.timeIntervalSince($0.endedAt ?? $0.startedAt)
                let rhsGap = ghostMeta.startedAt.timeIntervalSince($1.endedAt ?? $1.startedAt)
                return lhsGap < rhsGap
            }

        guard let target = candidates.first else { return nil }

        if let targetMeta = loadSessionMetadataFile(sessionID: target.id),
           targetMeta.calendarEvent == nil {
            updateSessionCalendarEvent(sessionID: target.id, calendarEvent: calendarEvent)
        }

        deleteSession(sessionID: sessionID)
        return target.id
    }

    /// Update source and tags for an imported session.
    func updateSessionSource(sessionID: String, source: String, tags: [String]) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID) else { return }
        meta.source = source
        let existingVisibleTags = Self.userVisibleSessionTags(from: meta.tags ?? [])
        let preservedInternalTags = Self.normalizeInternalSessionTags((meta.tags ?? []) + tags)
        let combinedTags = preservedInternalTags + Self.normalizeUserVisibleTags(existingVisibleTags)
        meta.tags = combinedTags.isEmpty ? nil : combinedTags
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Collect all unique tags across all sessions for autocomplete.
    func allTags() -> [String] {
        let sessions = listSessions()
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions {
            for tag in session.tags ?? [] {
                let lower = tag.lowercased()
                if !seen.contains(lower) {
                    seen.insert(lower)
                    result.append(tag)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append(trimmed)
            }
            if result.count >= 5 { break }
        }
        return result
    }

    private static func normalizeUserVisibleTags(_ tags: [String]) -> [String] {
        normalizeTags(userVisibleSessionTags(from: tags))
    }

    private static func normalizeInternalSessionTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in internalSessionTags(from: tags) {
            let key = tag.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(tag)
        }
        return result
    }

    private static func userVisibleSessionTags(from tags: [String]) -> [String] {
        tags.filter { !isInternalSessionTag($0) }
    }

    private static func internalSessionTags(from tags: [String]) -> [String] {
        tags.filter(isInternalSessionTag)
    }

    private static func normalizeSessionFolderPath(_ folderPath: String?) -> String? {
        NotesFolderDefinition.normalizePath(folderPath ?? "")
    }

    private func resumableSessionID(
        config: SessionStartConfig,
        maximumGap: TimeInterval
    ) -> String? {
        let referenceTitle = config.title ?? config.calendarEvent?.title
        let historyKey = MeetingHistoryResolver.historyKey(for: referenceTitle ?? "")
        guard !historyKey.isEmpty else { return nil }

        let referenceDate = config.calendarEvent?.startDate ?? Date()
        let referenceEventID = config.calendarEvent?.id

        let candidates = listSessions().compactMap { candidate -> (id: String, exactEventMatch: Bool, gap: TimeInterval)? in
            guard candidate.endedAt == nil,
                  candidate.utteranceCount == 0,
                  candidate.hasNotes == false,
                  !sessionHasMeaningfulArtifacts(sessionID: candidate.id),
                  let metadata = loadSessionMetadataFile(sessionID: candidate.id) else {
                return nil
            }

            let gap = abs(metadata.startedAt.timeIntervalSince(referenceDate))
            guard gap <= maximumGap else { return nil }

            if let referenceEventID,
               metadata.calendarEvent?.id == referenceEventID {
                return (candidate.id, true, gap)
            }

            let candidateTitle = metadata.title ?? metadata.calendarEvent?.title
            guard MeetingHistoryResolver.historyKey(for: candidateTitle ?? "") == historyKey else {
                return nil
            }

            return (candidate.id, false, gap)
        }
        .sorted { lhs, rhs in
            if lhs.exactEventMatch != rhs.exactEventMatch {
                return lhs.exactEventMatch && !rhs.exactEventMatch
            }
            return lhs.gap < rhs.gap
        }

        return candidates.first?.id
    }

    private func existingSessionID(
        for event: CalendarEvent,
        referenceDate: Date,
        maximumGap: TimeInterval = 6 * 60 * 60
    ) -> String? {
        let historyKey = MeetingHistoryResolver.historyKey(for: event)
        let referenceEventID = event.id

        let candidates = listSessions().compactMap { candidate -> (id: String, exactEventMatch: Bool, gap: TimeInterval)? in
            guard let metadata = loadSessionMetadataFile(sessionID: candidate.id) else {
                return nil
            }

            let gap = abs(metadata.startedAt.timeIntervalSince(referenceDate))
            guard gap <= maximumGap else { return nil }

            if metadata.calendarEvent?.id == referenceEventID {
                return (candidate.id, true, gap)
            }

            let candidateTitle = metadata.title ?? metadata.calendarEvent?.title
            guard MeetingHistoryResolver.historyKey(for: candidateTitle ?? "") == historyKey else {
                return nil
            }

            return (candidate.id, false, gap)
        }
        .sorted { lhs, rhs in
            if lhs.exactEventMatch != rhs.exactEventMatch {
                return lhs.exactEventMatch && !rhs.exactEventMatch
            }
            return lhs.gap < rhs.gap
        }

        return candidates.first?.id
    }

    private func sessionHasMeaningfulArtifacts(sessionID: String) -> Bool {
        if !loadTranscript(sessionID: sessionID).isEmpty { return true }
        if !loadLiveTranscript(sessionID: sessionID).isEmpty { return true }

        let audioDir = sessionDirectory(for: sessionID).appendingPathComponent("audio", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: audioDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return !contents.isEmpty
    }

    private static func isInternalSessionTag(_ tag: String) -> Bool {
        tag.lowercased().hasPrefix("granola:")
    }

    func deleteSession(sessionID: String) {
        // Stop tracking the session for mirror retries; nothing left to mirror.
        mirrorAttempts.forget(sessionID: sessionID)
        let fm = FileManager.default
        let dir = sessionDirectory(for: sessionID)

        // Remove canonical directory
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }

        // Also remove legacy files if present
        LegacySessionReader.deleteSession(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    // MARK: - Recently Deleted

    private var recentlyDeletedDirectory: URL {
        sessionsDirectory.appendingPathComponent(".recently-deleted", isDirectory: true)
    }

    func moveToRecentlyDeleted(sessionID: String) {
        mirrorAttempts.forget(sessionID: sessionID)
        let fm = FileManager.default
        try? fm.createDirectory(at: recentlyDeletedDirectory, withIntermediateDirectories: true)

        let dir = sessionDirectory(for: sessionID)
        if fm.fileExists(atPath: dir.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(dir.lastPathComponent)
            try? fm.moveItem(at: dir, to: dest)
        }

        // Also move legacy files
        LegacySessionReader.moveToRecentlyDeleted(
            sessionID: sessionID,
            sessionsDirectory: sessionsDirectory,
            recentlyDeletedDirectory: recentlyDeletedDirectory
        )
    }

    func purgeRecentlyDeleted() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: recentlyDeletedDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Plain Text Export

    func exportPlainText(sessionID: String) -> String {
        let records = loadTranscript(sessionID: sessionID)
        guard !records.isEmpty else { return "" }

        let meta = loadSessionMetadataFile(sessionID: sessionID)
        let startDate = meta?.startedAt ?? records.first?.timestamp ?? Date()

        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        var result = "OpenOats - \(headerFmt.string(from: startDate))\n\n"

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        for record in records {
            let displayText = record.cleanedText ?? record.text
            let speaker = record.speaker.displayName(speakerNames: meta?.speakerNames)
            result += "[\(timeFmt.string(from: record.timestamp))] \(speaker): \(displayText)\n"
        }

        return result
    }

    // MARK: - Batch Audio Persistence

    func stashAudioForBatch(
        sessionID: String,
        micURL: URL?,
        sysURL: URL?,
        anchors: BatchAnchors
    ) {
        let fm = FileManager.default
        let audioDir = sessionDirectory(for: sessionID).appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)

        if let src = micURL, fm.fileExists(atPath: src.path) {
            let dst = audioDir.appendingPathComponent("mic.caf")
            try? fm.moveItem(at: src, to: dst)
        }
        if let src = sysURL, fm.fileExists(atPath: src.path) {
            let dst = audioDir.appendingPathComponent("sys.caf")
            try? fm.moveItem(at: src, to: dst)
        }

        let meta = BatchMeta(
            micStartDate: anchors.micStartDate,
            sysStartDate: anchors.sysStartDate,
            micAnchors: anchors.micAnchors.map { .init(frame: $0.frame, date: $0.date) },
            sysAnchors: anchors.sysAnchors.map { .init(frame: $0.frame, date: $0.date) },
            sysEffectiveSampleRate: anchors.sysEffectiveSampleRate
        )
        if let data = try? JSONEncoder.iso8601Encoder.encode(meta) {
            try? data.write(to: audioDir.appendingPathComponent("batch-meta.json"), options: .atomic)
        }
    }

    func batchAudioURLs(sessionID: String) -> (mic: URL?, sys: URL?) {
        let fm = FileManager.default

        // Try canonical audio/ subdirectory first
        let audioDir = sessionDirectory(for: sessionID).appendingPathComponent("audio", isDirectory: true)
        let micCanonical = audioDir.appendingPathComponent("mic.caf")
        let sysCanonical = audioDir.appendingPathComponent("sys.caf")
        if fm.fileExists(atPath: micCanonical.path) || fm.fileExists(atPath: sysCanonical.path) {
            return (
                mic: fm.fileExists(atPath: micCanonical.path) ? micCanonical : nil,
                sys: fm.fileExists(atPath: sysCanonical.path) ? sysCanonical : nil
            )
        }

        // Fall back to legacy layout (files directly in session subdirectory)
        let dir = sessionDirectory(for: sessionID)
        let micLegacy = dir.appendingPathComponent("mic.caf")
        let sysLegacy = dir.appendingPathComponent("sys.caf")
        return (
            mic: fm.fileExists(atPath: micLegacy.path) ? micLegacy : nil,
            sys: fm.fileExists(atPath: sysLegacy.path) ? sysLegacy : nil
        )
    }

    func hasRetainedBatchAudio(sessionID: String) -> Bool {
        let urls = batchAudioURLs(sessionID: sessionID)
        return urls.mic != nil || urls.sys != nil
    }

    func hasPreBatchTranscriptBackup(sessionID: String) -> Bool {
        let backupURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.pre-batch.jsonl")
        guard FileManager.default.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: backupURL)
        else {
            return false
        }
        return !data.isEmpty
    }

    @discardableResult
    func restorePreBatchTranscript(sessionID: String) -> Bool {
        let backupURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.pre-batch.jsonl")
        guard let content = try? String(contentsOf: backupURL, encoding: .utf8) else { return false }
        let records = parseJSONL(content)
        guard !records.isEmpty else { return false }
        saveFinalTranscript(sessionID: sessionID, records: records)
        return true
    }

    /// Marks a session's retained audio as in use by a batch transcription run,
    /// which blocks the retention sweep and user deletion for that session.
    /// Balanced by `endBatchAudioAccess`.
    func beginBatchAudioAccess(sessionID: String) {
        activeBatchAudioAccessCounts[sessionID, default: 0] += 1
    }

    func endBatchAudioAccess(sessionID: String) {
        guard let count = activeBatchAudioAccessCounts[sessionID] else { return }
        if count <= 1 {
            activeBatchAudioAccessCounts.removeValue(forKey: sessionID)
        } else {
            activeBatchAudioAccessCounts[sessionID] = count - 1
        }
    }

    /// Removes retained batch audio for one session. Refuses (returns `false`)
    /// while a batch run is reading the stems, or when the session's `audio/`
    /// is a symlink and deleting would reach through it.
    @discardableResult
    func cleanupBatchAudio(sessionID: String) -> Bool {
        guard activeBatchAudioAccessCounts[sessionID] == nil else { return false }
        return Self.removeRetainedBatchAudio(inSessionDirectory: sessionDirectory(for: sessionID))
    }

    func loadBatchMeta(sessionID: String) -> BatchMeta? {
        // Try canonical audio/ path first
        let audioMetaURL = sessionDirectory(for: sessionID)
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("batch-meta.json")
        if let data = try? Data(contentsOf: audioMetaURL) {
            return try? decoder.decode(BatchMeta.self, from: data)
        }

        // Legacy path
        let legacyMetaURL = sessionDirectory(for: sessionID).appendingPathComponent("batch-meta.json")
        guard let data = try? Data(contentsOf: legacyMetaURL) else { return nil }
        return try? decoder.decode(BatchMeta.self, from: data)
    }



    // MARK: - Cleaned Text Backfill

    func backfillCleanedText(from utterances: [Utterance]) {
        guard let sessionID = currentSessionID else { return }

        try? liveFileHandle?.close()
        liveFileHandle = nil

        let liveURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.live.jsonl")
        rewriteJSONLWithCleanedText(file: liveURL, utterances: utterances)

        liveFileHandle = try? FileHandle(forWritingTo: liveURL)
    }

    func backfillCleanedText(sessionID: String, from utterances: [Utterance]) {
        let liveURL = sessionDirectory(for: sessionID).appendingPathComponent("transcript.live.jsonl")
        if FileManager.default.fileExists(atPath: liveURL.path) {
            rewriteJSONLWithCleanedText(file: liveURL, utterances: utterances)
            return
        }

        // Legacy fallback
        let legacyURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            rewriteJSONLWithCleanedText(file: legacyURL, utterances: utterances)
        }
    }

    // MARK: - Seeding (for tests / UI tests)

    func seedSession(
        id: String,
        records: [SessionRecord],
        startedAt: Date,
        endedAt: Date? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        notes: GeneratedNotes? = nil,
        transcriptIssue: SessionTranscriptIssue? = nil,
        transcriptRecovery: SessionTranscriptRecoveryState? = nil
    ) {
        let dir = sessionDirectory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write session.json
        let meta = SessionMetadata(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            templateSnapshot: templateSnapshot,
            title: title,
            utteranceCount: records.count,
            hasNotes: notes != nil,
            meetingApp: nil,
            engine: nil,
            transcriptIssue: transcriptIssue,
            transcriptRecovery: transcriptRecovery
        )
        writeSessionMetadata(meta, sessionID: id)

        // Write transcript.live.jsonl
        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(Data("\n".utf8))
            }
        }
        try? payload.write(to: liveURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveURL.path)

        // Write notes if provided
        if let notes {
            saveNotes(sessionID: id, notes: notes)
        }
    }

    // MARK: - Accessors

    nonisolated var sessionsDirectoryURL: URL { sessionsDirectory }

    func getCurrentSessionID() -> String? { currentSessionID }

    /// Returns the default playable audio source URL for a session, if one exists.
    func audioFileURL(for sessionID: String) -> URL? {
        audioSources(for: sessionID).first?.url
    }

    func audioSources(for sessionID: String) -> [SessionAudioSource] {
        SessionRepository.readAudioSources(dir: sessionDirectory(for: sessionID))
    }

    // MARK: - Concurrent Session Loading

    /// Loads notes, transcript, audio sources, and persisted calendar context concurrently off the actor.
    /// Prefer this over separate awaited calls to avoid sequential actor hops.
    nonisolated func loadSessionData(
        sessionID: String
    ) async -> (
        notes: GeneratedNotes?,
        transcript: [SessionRecord],
        audioURL: URL?,
        audioSources: [SessionAudioSource],
        calendarEvent: CalendarEvent?,
        attachments: [NoteAttachment]
    ) {
        let sessDir = sessionsDirectoryURL
        let dir = sessDir.appendingPathComponent(sessionID, isDirectory: true)

        async let notes = Task.detached(priority: .userInitiated) {
            SessionRepository.readNotes(sessionID: sessionID, dir: dir, sessionsDirectory: sessDir)
        }.value
        async let transcript = Task.detached(priority: .userInitiated) {
            SessionRepository.readTranscript(sessionID: sessionID, dir: dir, sessionsDirectory: sessDir)
        }.value
        async let audioSources = Task.detached(priority: .userInitiated) {
            SessionRepository.readAudioSources(dir: dir)
        }.value
        async let calendarEvent = Task.detached(priority: .userInitiated) {
            SessionRepository.readCalendarEvent(dir: dir)
        }.value
        async let attachments = Task.detached(priority: .userInitiated) {
            SessionRepository.readNoteAttachments(dir: dir)
        }.value

        let resolvedAudioSources = await audioSources
        return await (
            notes,
            transcript,
            resolvedAudioSources.first?.url,
            resolvedAudioSources,
            calendarEvent,
            attachments
        )
    }

    private nonisolated static func readNotes(sessionID: String, dir: URL, sessionsDirectory: URL) -> GeneratedNotes? {
        let mdURL = dir.appendingPathComponent("notes.md")

        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
           let meta = readNotesMeta(dir: dir) {
            return GeneratedNotes(template: meta.templateSnapshot, generatedAt: meta.generatedAt, markdown: markdown)
        }

        return LegacySessionReader.loadNotes(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    private nonisolated static func readNoteAttachments(dir: URL) -> [NoteAttachment] {
        (readNotesMeta(dir: dir)?.attachments ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private nonisolated static func readNotesMeta(dir: URL) -> NotesMeta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metaURL = dir.appendingPathComponent("notes.meta.json")
        guard let metaData = try? Data(contentsOf: metaURL) else { return nil }
        return try? decoder.decode(NotesMeta.self, from: metaData)
    }

    private nonisolated static func readCalendarEvent(dir: URL) -> CalendarEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metaURL = dir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? decoder.decode(SessionMetadata.self, from: data) else {
            return nil
        }
        return meta.calendarEvent
    }

    private nonisolated static func readTranscript(sessionID: String, dir: URL, sessionsDirectory: URL) -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func parse(_ content: String) -> [SessionRecord] {
            content.components(separatedBy: "\n").filter { !$0.isEmpty }.compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
        }

        let finalURL = dir.appendingPathComponent("transcript.final.jsonl")
        if FileManager.default.fileExists(atPath: finalURL.path),
           let content = try? String(contentsOf: finalURL, encoding: .utf8) {
            let records = parse(content)
            if !records.isEmpty { return records }
        }

        let liveURL = dir.appendingPathComponent("transcript.live.jsonl")
        if FileManager.default.fileExists(atPath: liveURL.path),
           let content = try? String(contentsOf: liveURL, encoding: .utf8) {
            let records = parse(content)
            if !records.isEmpty { return records }
        }

        return LegacySessionReader.loadTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    private nonisolated static func readAudioSources(dir: URL) -> [SessionAudioSource] {
        let fm = FileManager.default
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        var sources: [SessionAudioSource] = []

        if let url = readPrimaryPlayableAudioURL(in: audioDir) ?? readPrimaryPlayableAudioURL(in: dir) {
            sources.append(SessionAudioSource(kind: .recording, url: url))
        }

        let canonicalSystemURL = audioDir.appendingPathComponent("sys.caf")
        let legacySystemURL = dir.appendingPathComponent("sys.caf")
        if fm.fileExists(atPath: canonicalSystemURL.path) {
            sources.append(SessionAudioSource(kind: .system, url: canonicalSystemURL))
        } else if fm.fileExists(atPath: legacySystemURL.path) {
            sources.append(SessionAudioSource(kind: .system, url: legacySystemURL))
        }

        let canonicalMicURL = audioDir.appendingPathComponent("mic.caf")
        let legacyMicURL = dir.appendingPathComponent("mic.caf")
        if fm.fileExists(atPath: canonicalMicURL.path) {
            sources.append(SessionAudioSource(kind: .microphone, url: canonicalMicURL))
        } else if fm.fileExists(atPath: legacyMicURL.path) {
            sources.append(SessionAudioSource(kind: .microphone, url: legacyMicURL))
        }

        return sources
    }

    private nonisolated static func readPrimaryPlayableAudioURL(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let skipExtensions: Set<String> = ["caf", "json"]
        let skipFilenames: Set<String> = [
            "session.json",
            "transcript.live.jsonl",
            "transcript.final.jsonl",
            "notes.md",
            "notes.meta.json",
            "batch-meta.json",
            "mic.caf",
            "sys.caf",
        ]
        return contents
            .filter {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: $0.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    return false
                }
                guard !skipFilenames.contains($0.lastPathComponent.lowercased()) else {
                    return false
                }
                let pathExtension = $0.pathExtension.lowercased()
                guard !skipExtensions.contains(pathExtension) else { return false }
                guard let contentType = UTType(filenameExtension: pathExtension) else { return false }
                return contentType.conforms(to: .audio)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    // MARK: - Private Helpers

    private func sessionDirectory(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func attachmentsDirectory(for sessionID: String) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("attachments", isDirectory: true)
    }

    private func writeSessionMetadata(_ metadata: SessionMetadata, sessionID: String) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("session.json")
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(metadata)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.sessionRepository.error("Failed to write session.json: \(error, privacy: .public)")
        }
    }

    private func loadSessionMetadataFile(sessionID: String) -> SessionMetadata? {
        let url = sessionDirectory(for: sessionID).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionMetadata.self, from: data)
    }

    private func loadNotesMeta(sessionID: String) -> NotesMeta? {
        Self.readNotesMeta(dir: sessionDirectory(for: sessionID))
    }

    private func saveNotesMeta(_ meta: NotesMeta, sessionID: String) {
        let metaURL = sessionDirectory(for: sessionID).appendingPathComponent("notes.meta.json")
        if let data = try? encoder.encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        }
    }

    private nonisolated static func sanitizedAttachmentFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let raw = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return raw.isEmpty ? "attachment" : raw
    }

    private func parseJSONL(_ content: String) -> [SessionRecord] {
        content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
    }

    private func reportWriteError(_ message: String) {
        Log.sessionRepository.error("\(message, privacy: .public)")
        guard !hasReportedWriteError else { return }
        hasReportedWriteError = true
        onWriteError?(message)
    }

    private func openLiveTranscriptFileHandle(sessionID: String) {
        try? liveFileHandle?.close()
        liveFileHandle = nil

        let liveFile = sessionDirectory(for: sessionID).appendingPathComponent("transcript.live.jsonl")
        let fm = FileManager.default
        if !fm.fileExists(atPath: liveFile.path) {
            fm.createFile(
                atPath: liveFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        do {
            let handle = try FileHandle(forWritingTo: liveFile)
            handle.seekToEndOfFile()
            liveFileHandle = handle
        } catch {
            reportWriteError("Failed to open live transcript file: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func rewriteJSONLWithCleanedText(file: URL, utterances: [Utterance]) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }

        let backupURL = file.appendingPathExtension("pre-cleanup.bak")
        try? FileManager.default.copyItem(at: file, to: backupURL)

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var cleanedLookup: [String: String] = [:]
        for utterance in utterances {
            guard let cleaned = utterance.cleanedText else { continue }
            let key = "\(iso8601Formatter.string(from: utterance.timestamp))|\(utterance.speaker.storageKey)"
            cleanedLookup[key] = cleaned
        }

        guard !cleanedLookup.isEmpty else { return false }

        var updatedLines: [String] = []
        var anyUpdated = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  var record = try? decoder.decode(SessionRecord.self, from: data) else {
                updatedLines.append(line)
                continue
            }

            if record.cleanedText == nil {
                let key = "\(iso8601Formatter.string(from: record.timestamp))|\(record.speaker.storageKey)"
                if let cleaned = cleanedLookup[key] {
                    record = record.withCleanedText(cleaned)
                    anyUpdated = true
                }
            }

            if let encoded = try? encoder.encode(record),
               let jsonString = String(data: encoded, encoding: .utf8) {
                updatedLines.append(jsonString)
            } else {
                updatedLines.append(line)
            }
        }

        if anyUpdated {
            let newContent = updatedLines.joined(separator: "\n") + "\n"
            try? newContent.write(to: file, atomically: true, encoding: .utf8)
        }

        return anyUpdated
    }

    // MARK: - Notes Folder Mirroring

    /// Schedule a background mirror of the session's notes and transcript to notesFolderPath.
    /// When notes reference session-local assets, the mirror is written as a small package
    /// directory so relative links remain valid.
    /// Captures all actor-isolated state before spawning so the work runs entirely off-actor.
    /// - Parameter notesMarkdown: Pass the markdown when already in memory (e.g. from saveNotes)
    ///   to avoid a redundant disk read; nil causes the background task to read it from disk.
    private func scheduleMirror(sessionID: String, notesMarkdown: String? = nil) {
        startMirrorAttempt(sessionID: sessionID, notesMarkdown: notesMarkdown)
        retryPendingMirrors(excluding: sessionID)
    }

    /// Scan session metadata for mirrors that failed in a previous run and
    /// retry them. Called once from init.
    private func restorePendingMirrors() async {
        let sessDir = sessionsDirectory
        let pending = await Task.detached(priority: .utility) {
            SessionRepository.scanPendingMirrorSessionIDs(in: sessDir)
        }.value
        mirrorAttempts.restorePending(pending)
        retryPendingMirrors()
    }

    /// Read the durable `mirrorPending` flags off the actor. The scan decodes
    /// one JSON file per session directory; running it actor-isolated would
    /// queue every other repository call behind it at launch.
    private nonisolated static func scanPendingMirrorSessionIDs(in sessionsDirectory: URL) -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var pending: Set<String> = []
        for entry in contents {
            let sessionID = entry.lastPathComponent
            // Canonical session directories only, matching the batch-audio
            // cleanup scan; this skips .recently-deleted and stray files.
            guard sessionID.hasPrefix("session_") else { continue }
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("session.json")),
                  let meta = try? decoder.decode(SessionMetadata.self, from: data),
                  meta.mirrorPending == true else { continue }
            pending.insert(sessionID)
        }
        return pending
    }

    /// Re-drive mirrors that previously failed (e.g. the notes folder lives on
    /// a network mount that was unreachable). Runs whenever the notes folder is
    /// (re)configured and piggybacks on every scheduled mirror, so pending
    /// exports heal as soon as the folder is reachable again.
    ///
    /// Only sessions with no attempt running and outside the failure backoff
    /// are driven, so a permanently dead mount costs at most one blocked
    /// attempt per pending session per backoff interval.
    private func retryPendingMirrors(excluding excludedSessionID: String? = nil) {
        guard notesFolderPath != nil else { return }
        for sessionID in mirrorAttempts.retryableSessionIDs(excluding: excludedSessionID) {
            startMirrorAttempt(sessionID: sessionID)
        }
    }

    /// Start one mirror attempt unless this session already has one running, in
    /// which case the request is coalesced into a single re-run.
    private func startMirrorAttempt(sessionID: String, notesMarkdown: String? = nil) {
        guard let outputDir = notesFolderPath else { return }
        guard let attempt = mirrorAttempts.beginAttempt(sessionID: sessionID) else {
            // An attempt is already running, possibly blocked on an unreachable
            // mount. Re-mirror once it reports so newer notes are not lost.
            mirrorAttempts.requestReschedule(sessionID: sessionID)
            return
        }
        let sessDir = sessionsDirectory
        let isSecurityScoped = notesFolderIsSecurityScoped
        let dateSubfolderFormat = meetingTranscriptDateFolderFormat
        let meta = loadSessionMetadataFile(sessionID: sessionID)
        Task.detached(priority: .background) { [weak self] in
            let succeeded = SessionRepository.performMirror(
                sessionID: sessionID,
                meta: meta,
                notesMarkdown: notesMarkdown,
                outputDir: outputDir,
                isSecurityScoped: isSecurityScoped,
                dateSubfolderFormat: dateSubfolderFormat,
                sessionsDirectory: sessDir
            )
            await self?.mirrorDidFinish(sessionID: sessionID, attempt: attempt, succeeded: succeeded)
        }
    }

    /// Record the outcome of a mirror attempt, persisting a pending flag in the
    /// session metadata so a failed export survives an app relaunch.
    ///
    /// Reports from superseded attempts are dropped: a session deleted (and so
    /// forgotten) mid-attempt can start a fresh attempt afterwards, and a slow
    /// success from the old one must not clear the newer attempt's pending flag.
    private func mirrorDidFinish(sessionID: String, attempt: Int, succeeded: Bool) {
        switch mirrorAttempts.finishAttempt(
            sessionID: sessionID,
            attempt: attempt,
            succeeded: succeeded
        ) {
        case .ignored:
            return

        case .staleDestination:
            // The attempt wrote to the folder the user has since replaced, so
            // the current one still has no export: keep the durable flag and
            // re-drive now that the session's attempt slot is free. A request
            // coalesced during the attempt is satisfied by that same re-run.
            persistMirrorPending(true, sessionID: sessionID)
            _ = mirrorAttempts.takeRescheduleRequest(sessionID: sessionID)
            startMirrorAttempt(sessionID: sessionID)

        case .recorded:
            persistMirrorPending(!succeeded, sessionID: sessionID)

            let hasQueuedRequest = mirrorAttempts.takeRescheduleRequest(sessionID: sessionID)
            // On failure the session is already pending and the backoff governs
            // the next attempt, so only a success re-drives a coalesced request.
            if succeeded, hasQueuedRequest {
                startMirrorAttempt(sessionID: sessionID)
            }
        }
    }

    private func persistMirrorPending(_ pending: Bool, sessionID: String) {
        guard var meta = loadSessionMetadataFile(sessionID: sessionID),
              (meta.mirrorPending == true) != pending else { return }
        meta.mirrorPending = pending ? true : nil
        writeSessionMetadata(meta, sessionID: sessionID)
    }

    /// Returns `true` when the mirror was written (or there was nothing to
    /// mirror), `false` when the export failed and should be retried.
    private nonisolated static func performMirror(
        sessionID: String,
        meta: SessionMetadata?,
        notesMarkdown: String?,
        outputDir: URL,
        isSecurityScoped: Bool,
        dateSubfolderFormat: MeetingTranscriptDateFolderFormat?,
        sessionsDirectory: URL
    ) -> Bool {
        // Acquire security-scoped access if the URL was resolved from a bookmark
        let didStartAccess = isSecurityScoped && outputDir.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { outputDir.stopAccessingSecurityScopedResource() }
        }

        let dir = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        let records = readTranscript(sessionID: sessionID, dir: dir, sessionsDirectory: sessionsDirectory)
        guard !records.isEmpty else { return true }

        let resolvedMarkdown = notesMarkdown
            ?? readNotes(sessionID: sessionID, dir: dir, sessionsDirectory: sessionsDirectory)?.markdown
        let referencedAssetPaths = resolvedMarkdown.map(Self.referencedMirrorAssetPaths(in:)) ?? []

        let index = SessionIndex(
            id: meta?.id ?? sessionID,
            startedAt: meta?.startedAt ?? records.first?.timestamp ?? Date(),
            endedAt: meta?.endedAt,
            templateSnapshot: meta?.templateSnapshot,
            title: meta?.title,
            utteranceCount: meta?.utteranceCount ?? records.count,
            hasNotes: (meta?.hasNotes ?? false) || resolvedMarkdown != nil,
            language: meta?.language,
            meetingApp: meta?.meetingApp,
            engine: meta?.engine,
            tags: meta?.tags,
            folderPath: meta?.folderPath,
            source: meta?.source,
            meetingFamilyKey: meta?.calendarEvent.flatMap { MeetingHistoryResolver.seriesHistoryKey(for: $0) },
            transcriptIssue: meta?.transcriptIssue,
            transcriptRecovery: meta?.transcriptRecovery,
            speakerNames: meta?.speakerNames
        )

        let outputTarget = MarkdownMeetingWriter.write(
            metadata: .init(from: index),
            records: records,
            notesMarkdown: resolvedMarkdown,
            outputDirectory: mirrorDirectory(outputDir, format: dateSubfolderFormat, startedAt: index.startedAt),
            preferPackage: !referencedAssetPaths.isEmpty
        )

        guard let outputTarget else { return false }

        if let packageDirectoryURL = outputTarget.packageDirectoryURL {
            return synchronizeMirroredAssets(
                referencedAssetPaths: referencedAssetPaths,
                from: dir,
                into: packageDirectoryURL
            )
        }
        return true
    }

    private nonisolated static func mirrorDirectory(
        _ outputDir: URL,
        format: MeetingTranscriptDateFolderFormat?,
        startedAt: Date
    ) -> URL {
        guard let format else { return outputDir }
        return outputDir.appendingPathComponent(format.folderName(for: startedAt), isDirectory: true)
    }

    private nonisolated static func referencedMirrorAssetPaths(in markdown: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"!?\[[^\]]*\]\(([^)]+)\)"#) else {
            return []
        }

        let nsMarkdown = markdown as NSString
        let range = NSRange(location: 0, length: nsMarkdown.length)
        var paths: Set<String> = []

        for match in regex.matches(in: markdown, range: range) {
            guard match.numberOfRanges > 1 else { continue }
            let rawTarget = nsMarkdown.substring(with: match.range(at: 1))
            if let normalizedPath = normalizedMirrorAssetPath(rawTarget) {
                paths.insert(normalizedPath)
            }
        }

        return paths
    }

    private nonisolated static func normalizedMirrorAssetPath(_ rawTarget: String) -> String? {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("<"), target.hasSuffix(">"), target.count >= 2 {
            target.removeFirst()
            target.removeLast()
        }

        guard !target.isEmpty else { return nil }

        if let fragmentIndex = target.firstIndex(of: "#") {
            target = String(target[..<fragmentIndex])
        }
        if let queryIndex = target.firstIndex(of: "?") {
            target = String(target[..<queryIndex])
        }

        guard !target.isEmpty,
              !target.hasPrefix("/"),
              !target.hasPrefix("~"),
              URL(string: target)?.scheme == nil else {
            return nil
        }

        let components = target
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let first = components.first,
              first == "attachments" || first == "images",
              !components.contains(".."),
              !components.contains(".") else {
            return nil
        }

        return components.joined(separator: "/")
    }

    /// Copy the assets a mirrored note references into the package directory.
    /// - Returns: `false` when a referenced asset exists but could not be
    ///   copied, so the mirror is retried. A referenced asset that is missing
    ///   from the session is skipped and does not fail the mirror — retrying
    ///   would never bring it back.
    @discardableResult
    private nonisolated static func synchronizeMirroredAssets(
        referencedAssetPaths: Set<String>,
        from sessionDirectory: URL,
        into packageDirectory: URL
    ) -> Bool {
        let fm = FileManager.default
        let mirroredAssetDirectories = [
            packageDirectory.appendingPathComponent("attachments", isDirectory: true),
            packageDirectory.appendingPathComponent("images", isDirectory: true),
        ]

        for directory in mirroredAssetDirectories {
            try? fm.removeItem(at: directory)
        }

        guard !referencedAssetPaths.isEmpty else { return true }

        var allCopied = true
        for relativePath in referencedAssetPaths.sorted() {
            let sourceURL = sessionDirectory.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: sourceURL.path) else { continue }

            let destinationURL = packageDirectory.appendingPathComponent(relativePath)
            let parentDirectory = destinationURL.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.copyItem(at: sourceURL, to: destinationURL)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            } catch {
                Log.sessionRepository.error("Failed to mirror note asset \(relativePath, privacy: .public): \(error, privacy: .public)")
                allCopied = false
            }
        }
        return allCopied
    }

    // MARK: - Spotlight

    private static func dropMetadataNeverIndex(in directory: URL) {
        let sentinel = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    // MARK: - Orphan Cleanup

    /// Re-evaluates retained batch audio against the current retention setting.
    /// Sessions with an in-flight batch run are skipped.
    func sweepExpiredRetainedBatchAudio() {
        let removed = Self.cleanupExpiredRetainedBatchAudio(
            in: sessionsDirectory,
            olderThan: batchAudioRetention(),
            excluding: Set(activeBatchAudioAccessCounts.keys)
        )
        if !removed.isEmpty {
            onRetainedAudioSwept?(removed)
        }
    }

    /// Deletes retained batch audio whose newest artifact is older than `retention`.
    /// A `nil` retention means keep forever. Returns the affected session IDs.
    @discardableResult
    static func cleanupExpiredRetainedBatchAudio(
        in sessionsDirectory: URL,
        olderThan retention: TimeInterval?,
        excluding activeSessionIDs: Set<String> = [],
        now: Date = Date()
    ) -> [String] {
        guard let retention else { return [] }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-retention)
        var removed: [String] = []

        for item in contents {
            // Skip symlinks: resource values follow links, so a symlink named
            // session_* would otherwise delete its target's stems.
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }

            let name = item.lastPathComponent
            guard name.hasPrefix("session_") else { continue }
            guard !activeSessionIDs.contains(name) else { continue }

            let dates = retainedBatchAudioDates(inSessionDirectory: item)

            // An artifact whose date could not be read has an unknown age. This
            // sweep unlinks user audio, so unknown state means keep: without
            // this guard a present-but-unreadable stem looks identical to an
            // absent one, and an expired batch-meta.json would delete stems
            // that were never shown to be old.
            if dates.hasUnreadable {
                Log.sessionRepository.info(
                    "Keeping retained batch audio in \(name, privacy: .public): modification date unreadable"
                )
            }
            guard retainedBatchAudioIsExpired(dates, cutoff: cutoff) else { continue }

            guard removeRetainedBatchAudio(inSessionDirectory: item) else {
                Log.sessionRepository.info(
                    "Keeping retained batch audio in \(name, privacy: .public): audio/ is a symlink"
                )
                continue
            }
            removed.append(name)
            Log.sessionRepository.info("Cleaned up expired retained batch audio in \(name, privacy: .public)")
        }
        return removed
    }

    /// The date that decides retained-audio expiry: the newest modification date
    /// among mic.caf / sys.caf / batch-meta.json in the canonical and legacy
    /// layouts. The session directory's own date is deliberately ignored —
    /// unrelated metadata writes (notes edits, speaker renames) bump it and
    /// would reset the TTL indefinitely. Returns `nil` when the session has no
    /// retained audio stems.
    static func newestRetainedBatchAudioModificationDate(inSessionDirectory sessionDirectory: URL) -> Date? {
        let dates = retainedBatchAudioDates(inSessionDirectory: sessionDirectory)
        guard !dates.hasUnreadable, let stems = dates.stems else { return nil }
        return max(stems, dates.metadata ?? stems)
    }

    /// Whether a session's retained audio has expired, given its artifact dates.
    /// Pure, so the fail-open rules can be asserted directly rather than through
    /// filesystem states that are hard to stage without also blocking deletion.
    static func retainedBatchAudioIsExpired(
        _ dates: RetainedBatchAudioDates,
        cutoff: Date
    ) -> Bool {
        // An artifact whose date could not be read has an unknown age, and this
        // sweep unlinks user audio, so unknown means keep. Without this a
        // present-but-unreadable stem is indistinguishable from an absent one,
        // and an expired batch-meta.json would delete stems that were never
        // shown to be old.
        guard !dates.hasUnreadable else { return false }

        if let stems = dates.stems {
            return max(stems, dates.metadata ?? stems) < cutoff
        }
        if let metadata = dates.metadata {
            // No stems left: a lone batch-meta.json would otherwise live forever.
            return metadata < cutoff
        }
        return false
    }

    /// Modification dates of a session's retained audio artifacts.
    struct RetainedBatchAudioDates {
        /// Newest date among the mic/sys stems, or `nil` when none are present.
        var stems: Date?
        /// Newest date among the batch-meta.json files, or `nil` when absent.
        var metadata: Date?
        /// True when an artifact is present but its date could not be read.
        /// Callers that delete must treat this as "age unknown" and keep.
        var hasUnreadable: Bool
    }

    static func retainedBatchAudioDates(
        inSessionDirectory sessionDirectory: URL
    ) -> RetainedBatchAudioDates {
        let audioDir = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        let audioStems = [
            audioDir.appendingPathComponent("mic.caf"),
            audioDir.appendingPathComponent("sys.caf"),
            sessionDirectory.appendingPathComponent("mic.caf"),
            sessionDirectory.appendingPathComponent("sys.caf"),
        ]
        let metadataFiles = [
            audioDir.appendingPathComponent("batch-meta.json"),
            sessionDirectory.appendingPathComponent("batch-meta.json"),
        ]

        var result = RetainedBatchAudioDates(stems: nil, metadata: nil, hasUnreadable: false)
        for url in audioStems {
            switch modificationDate(of: url) {
            case .date(let date): result.stems = max(result.stems ?? date, date)
            case .unreadable: result.hasUnreadable = true
            case .absent: continue
            }
        }
        for url in metadataFiles {
            switch modificationDate(of: url) {
            case .date(let date): result.metadata = max(result.metadata ?? date, date)
            case .unreadable: result.hasUnreadable = true
            case .absent: continue
            }
        }
        return result
    }

    /// Why a modification date is unavailable, which a plain `Date?` cannot say.
    /// "Not there" and "there but unreadable" call for opposite decisions when
    /// the answer drives a deletion.
    enum ModificationDateResult: Equatable {
        case date(Date)
        case absent
        case unreadable
    }

    static func modificationDate(of url: URL) -> ModificationDateResult {
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else { return .unreadable }
            return .date(date)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile
            || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
    }

    /// Removes retained batch audio artifacts in both canonical and legacy
    /// layouts. Returns `false` without deleting anything when `audio/` is a
    /// symlink.
    ///
    /// `removeItem` resolves every path component but the last, so
    /// `<session>/audio/mic.caf` deletes through a symlinked `audio/` and takes
    /// the real file on the other volume with it. Relocating `audio/` is exactly
    /// what a user storing gigabytes per meeting is likely to have done, so the
    /// canonical removals are refused rather than redirected.
    @discardableResult
    static func removeRetainedBatchAudio(inSessionDirectory sessionDirectory: URL) -> Bool {
        let fm = FileManager.default

        let audioDir = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        if isSymbolicLink(audioDir) { return false }

        // Canonical audio/ layout
        try? fm.removeItem(at: audioDir.appendingPathComponent("mic.caf"))
        try? fm.removeItem(at: audioDir.appendingPathComponent("sys.caf"))
        try? fm.removeItem(at: audioDir.appendingPathComponent("batch-meta.json"))

        // Legacy layout (files directly in the session directory)
        try? fm.removeItem(at: sessionDirectory.appendingPathComponent("mic.caf"))
        try? fm.removeItem(at: sessionDirectory.appendingPathComponent("sys.caf"))
        try? fm.removeItem(at: sessionDirectory.appendingPathComponent("batch-meta.json"))
        return true
    }

    /// Whether `url` is itself a symlink. Uses the no-follow attribute lookup:
    /// `resourceValues(forKeys: [.isSymbolicLinkKey])` answers about the link,
    /// but only when the link resolves.
    static func isSymbolicLink(_ url: URL) -> Bool {
        guard let type = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }
}

// MARK: - Batch Transcription Support Types

/// Timing anchor data passed from AudioRecorder to SessionRepository.
struct BatchAnchors: Sendable {
    let micStartDate: Date?
    let sysStartDate: Date?
    let micAnchors: [(frame: Int64, date: Date)]
    let sysAnchors: [(frame: Int64, date: Date)]
    let sysEffectiveSampleRate: Double?
}

/// Codable batch metadata persisted as batch-meta.json.
struct BatchMeta: Codable, Sendable {
    let micStartDate: Date?
    let sysStartDate: Date?
    let micAnchors: [TimingAnchor]
    let sysAnchors: [TimingAnchor]
    let sysEffectiveSampleRate: Double?

    struct TimingAnchor: Codable, Sendable {
        let frame: Int64
        let date: Date
    }
}

extension JSONEncoder {
    static let iso8601Encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
