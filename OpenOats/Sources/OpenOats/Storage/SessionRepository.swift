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

    init(templateID: UUID? = nil, templateSnapshot: TemplateSnapshot? = nil) {
        self.templateID = templateID
        self.templateSnapshot = templateSnapshot
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

    init(
        endedAt: Date,
        utteranceCount: Int,
        title: String?,
        language: String?,
        meetingApp: String?,
        engine: String?,
        templateSnapshot: TemplateSnapshot?,
        utterances: [Utterance],
        calendarEvent: CalendarEvent? = nil
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
    }
}

/// Full session detail for loading.
struct SessionDetail: Sendable {
    let index: SessionIndex
    let transcript: [SessionRecord]
    let liveTranscript: [SessionRecord]
    let notes: GeneratedNotes?
    let notesMeta: NotesMeta?
    let calendarEvent: CalendarEvent?

    init(
        index: SessionIndex,
        transcript: [SessionRecord],
        liveTranscript: [SessionRecord],
        notes: GeneratedNotes?,
        notesMeta: NotesMeta?,
        calendarEvent: CalendarEvent? = nil
    ) {
        self.index = index
        self.transcript = transcript
        self.liveTranscript = liveTranscript
        self.notes = notes
        self.notesMeta = notesMeta
        self.calendarEvent = calendarEvent
    }
}

/// Metadata persisted alongside notes.
struct NotesMeta: Codable, Sendable {
    let templateSnapshot: TemplateSnapshot
    let generatedAt: Date
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
/// sessions/<id>/audio/
/// ```
actor SessionRepository {
    /// Retain batch stems/metadata long enough to support true reruns and debugging.
    private static let retainedBatchAudioLifetime: TimeInterval = 7 * 24 * 3600

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

    /// Whether `notesFolderPath` is a security-scoped URL that requires
    /// `startAccessingSecurityScopedResource()` before file I/O.
    private var notesFolderIsSecurityScoped = false

    init(rootDirectory: URL? = nil) {
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

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: sessionsDirectory)

        Self.cleanupExpiredRetainedBatchAudio(in: sessionsDirectory)
    }

    // MARK: - Configuration

    /// Update the notes folder path used for mirroring artifacts.
    /// - Parameters:
    ///   - url: The folder URL (may be a security-scoped URL resolved from a bookmark).
    ///   - securityScoped: Pass `true` when the URL was resolved from a security-scoped bookmark.
    func setNotesFolderPath(_ url: URL?, securityScoped: Bool = false) {
        notesFolderPath = url
        notesFolderIsSecurityScoped = securityScoped
    }

    /// Register a callback invoked once per session when a write error occurs.
    func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
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

        // Create transcript.live.jsonl and keep handle open
        let liveFile = sessionDir.appendingPathComponent("transcript.live.jsonl")
        fm.createFile(atPath: liveFile.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        do {
            liveFileHandle = try FileHandle(forWritingTo: liveFile)
        } catch {
            reportWriteError("Failed to open live transcript file: \(error.localizedDescription)")
        }

        // Write initial session.json
        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: Date(),
            templateSnapshot: config.templateSnapshot,
            utteranceCount: 0,
            hasNotes: false
        )
        writeSessionMetadata(metadata, sessionID: sessionID)

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

        // Write session.json with final metadata
        let sessionMeta = SessionMetadata(
            id: sessionID,
            startedAt: metadata.utterances.first?.timestamp ?? Date(),
            endedAt: metadata.endedAt,
            templateSnapshot: metadata.templateSnapshot,
            title: metadata.title,
            utteranceCount: metadata.utteranceCount,
            hasNotes: false,
            language: metadata.language,
            meetingApp: metadata.meetingApp,
            engine: metadata.engine,
            calendarEvent: metadata.calendarEvent
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
            source: "imported"
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

    func saveFinalTranscript(sessionID: String, records: [SessionRecord]) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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
                calendarEvent: meta.calendarEvent
            )
            writeSessionMetadata(refreshedMeta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath
        scheduleMirror(sessionID: sessionID)
    }

    // MARK: - Notes

    func saveNotes(sessionID: String, notes: GeneratedNotes) {
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write notes.md
        let mdURL = dir.appendingPathComponent("notes.md")
        try? notes.markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        // Write notes.meta.json
        let meta = NotesMeta(
            templateSnapshot: notes.template,
            generatedAt: notes.generatedAt
        )
        if let data = try? encoder.encode(meta) {
            let metaURL = dir.appendingPathComponent("notes.meta.json")
            try? data.write(to: metaURL, options: .atomic)
        }

        // Update session.json hasNotes flag
        if var sessionMeta = loadSessionMetadataFile(sessionID: sessionID) {
            sessionMeta.hasNotes = true
            writeSessionMetadata(sessionMeta, sessionID: sessionID)
        }

        // Mirror to notesFolderPath — pass markdown through to avoid re-reading from disk
        scheduleMirror(sessionID: sessionID, notesMarkdown: notes.markdown)
    }

    func loadNotes(sessionID: String) -> GeneratedNotes? {
        let dir = sessionDirectory(for: sessionID)
        let mdURL = dir.appendingPathComponent("notes.md")
        let metaURL = dir.appendingPathComponent("notes.meta.json")

        guard let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? decoder.decode(NotesMeta.self, from: metaData) else {
            // Fall back to legacy
            return LegacySessionReader.loadNotes(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
        }

        return GeneratedNotes(
            template: meta.templateSnapshot,
            generatedAt: meta.generatedAt,
            markdown: markdown
        )
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
                        source: meta.source
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
                source: meta.source
            )

            let transcript = loadTranscript(sessionID: id)
            let liveTranscript = loadLiveTranscript(sessionID: id)
            let notes = loadNotes(sessionID: id)

            return SessionDetail(
                index: index,
                transcript: transcript,
                liveTranscript: liveTranscript,
                notes: notes,
                notesMeta: nil,
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
            source: index.source
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
            source: index.source
        )
        let dir = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            calendarEvent: calendarEvent
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
            result += "[\(timeFmt.string(from: record.timestamp))] \(record.speaker.displayLabel): \(displayText)\n"
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

    func cleanupBatchAudio(sessionID: String) {
        let fm = FileManager.default

        // Clean canonical audio/
        let audioDir = sessionDirectory(for: sessionID).appendingPathComponent("audio", isDirectory: true)
        try? fm.removeItem(at: audioDir.appendingPathComponent("mic.caf"))
        try? fm.removeItem(at: audioDir.appendingPathComponent("sys.caf"))
        try? fm.removeItem(at: audioDir.appendingPathComponent("batch-meta.json"))

        // Clean legacy layout
        let dir = sessionDirectory(for: sessionID)
        try? fm.removeItem(at: dir.appendingPathComponent("mic.caf"))
        try? fm.removeItem(at: dir.appendingPathComponent("sys.caf"))
        try? fm.removeItem(at: dir.appendingPathComponent("batch-meta.json"))
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
        notes: GeneratedNotes? = nil
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
            engine: nil
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
        calendarEvent: CalendarEvent?
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

        let resolvedAudioSources = await audioSources
        return await (notes, transcript, resolvedAudioSources.first?.url, resolvedAudioSources, calendarEvent)
    }

    private nonisolated static func readNotes(sessionID: String, dir: URL, sessionsDirectory: URL) -> GeneratedNotes? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mdURL = dir.appendingPathComponent("notes.md")
        let metaURL = dir.appendingPathComponent("notes.meta.json")

        if let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
           let metaData = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(NotesMeta.self, from: metaData) {
            return GeneratedNotes(template: meta.templateSnapshot, generatedAt: meta.generatedAt, markdown: markdown)
        }

        return LegacySessionReader.loadNotes(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
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
    /// Captures all actor-isolated state before spawning so the work runs entirely off-actor.
    /// - Parameter notesMarkdown: Pass the markdown when already in memory (e.g. from saveNotes)
    ///   to avoid a redundant disk read; nil causes the background task to read it from disk.
    private func scheduleMirror(sessionID: String, notesMarkdown: String? = nil) {
        guard let outputDir = notesFolderPath else { return }
        let sessDir = sessionsDirectory
        let isSecurityScoped = notesFolderIsSecurityScoped
        let meta = loadSessionMetadataFile(sessionID: sessionID)
        Task.detached(priority: .background) {
            SessionRepository.performMirror(
                sessionID: sessionID,
                meta: meta,
                notesMarkdown: notesMarkdown,
                outputDir: outputDir,
                isSecurityScoped: isSecurityScoped,
                sessionsDirectory: sessDir
            )
        }
    }

    private nonisolated static func performMirror(
        sessionID: String,
        meta: SessionMetadata?,
        notesMarkdown: String?,
        outputDir: URL,
        isSecurityScoped: Bool,
        sessionsDirectory: URL
    ) {
        // Acquire security-scoped access if the URL was resolved from a bookmark
        let didStartAccess = isSecurityScoped && outputDir.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { outputDir.stopAccessingSecurityScopedResource() }
        }

        let dir = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        let records = readTranscript(sessionID: sessionID, dir: dir, sessionsDirectory: sessionsDirectory)
        guard !records.isEmpty else { return }

        let resolvedMarkdown = notesMarkdown
            ?? readNotes(sessionID: sessionID, dir: dir, sessionsDirectory: sessionsDirectory)?.markdown

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
            source: meta?.source
        )

        MarkdownMeetingWriter.write(
            metadata: .init(from: index),
            records: records,
            notesMarkdown: resolvedMarkdown,
            outputDirectory: outputDir
        )
    }

    // MARK: - Spotlight

    private static func dropMetadataNeverIndex(in directory: URL) {
        let sentinel = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    // MARK: - Orphan Cleanup

    private static func cleanupExpiredRetainedBatchAudio(in sessionsDirectory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-retainedBatchAudioLifetime)

        for item in contents {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { continue }

            let name = item.lastPathComponent
            guard name.hasPrefix("session_") else { continue }

            // Check both canonical audio/ and legacy layout
            let audioDir = item.appendingPathComponent("audio", isDirectory: true)
            let micCanonical = audioDir.appendingPathComponent("mic.caf")
            let sysCanonical = audioDir.appendingPathComponent("sys.caf")
            let micLegacy = item.appendingPathComponent("mic.caf")
            let sysLegacy = item.appendingPathComponent("sys.caf")

            let hasAudio = fm.fileExists(atPath: micCanonical.path) ||
                           fm.fileExists(atPath: sysCanonical.path) ||
                           fm.fileExists(atPath: micLegacy.path) ||
                           fm.fileExists(atPath: sysLegacy.path)

            guard hasAudio else { continue }

            if let modDate = values.contentModificationDate, modDate < cutoff {
                try? fm.removeItem(at: micCanonical)
                try? fm.removeItem(at: sysCanonical)
                try? fm.removeItem(at: audioDir.appendingPathComponent("batch-meta.json"))
                try? fm.removeItem(at: micLegacy)
                try? fm.removeItem(at: sysLegacy)
                try? fm.removeItem(at: item.appendingPathComponent("batch-meta.json"))
                Log.sessionRepository.info("Cleaned up expired retained batch audio in \(name, privacy: .public)")
            }
        }
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
