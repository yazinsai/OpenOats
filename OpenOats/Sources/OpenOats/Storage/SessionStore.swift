import Foundation

/// Persists session transcripts as JSONL files with metadata sidecars.
actor SessionStore {
    private let sessionsDirectory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()

    /// The filename stem of the current session (e.g. "session_2026-03-18_14-30-00").
    private(set) var currentSessionID: String?

    /// Tracks in-flight delayed writes.
    private var pendingWrites = 0
    private var pendingWriteWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called (once) when a write error occurs during the session.
    private var onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    init(rootDirectory: URL? = nil) {
        let baseDirectory: URL
        if let rootDirectory {
            baseDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDirectory = appSupport.appendingPathComponent("OpenOats", isDirectory: true)
        }
        sessionsDirectory = baseDirectory.appendingPathComponent("sessions", isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: sessionsDirectory)

        encoder.dateEncodingStrategy = .iso8601

        // Clean up orphaned batch audio older than 24 hours
        Self.cleanupOrphanedBatchAudio(in: sessionsDirectory)
    }

    /// Place a .metadata_never_index sentinel so Spotlight skips this directory.
    private static func dropMetadataNeverIndex(in directory: URL) {
        let sentinel = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    func startSession(templateID: UUID? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "session_\(formatter.string(from: Date()))"
        currentSessionID = stem
        hasReportedWriteError = false
        let filename = "\(stem).jsonl"
        let file = sessionsDirectory.appendingPathComponent(filename)
        currentFile = file

        FileManager.default.createFile(atPath: file.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        do {
            fileHandle = try FileHandle(forWritingTo: file)
        } catch {
            reportWriteError("Failed to open session file: \(error.localizedDescription)")
        }
    }

    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle else {
            reportWriteError("No file handle available for session write")
            return
        }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
        } catch {
            reportWriteError("Failed to write record: \(error.localizedDescription)")
        }
    }

    /// Owns the delayed THEM write: sleeps 5 seconds to capture pipeline results, then writes.
    /// The actor tracks in-flight delayed writes so `awaitPendingWrites()` can drain them.
    func appendRecordDelayed(
        baseRecord: SessionRecord,
        utteranceID: UUID? = nil,
        suggestionEngine: SuggestionEngine?,
        transcriptStore: TranscriptStore?
    ) {
        pendingWrites += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))

            guard let self else { return }

            // Capture pipeline results after delay
            let decision = await suggestionEngine?.lastDecision
            let latestSuggestion = await suggestionEngine?.suggestions.first
            let summary = await transcriptStore?.conversationState.shortSummary

            // Capture refined text from transcript store (may have been updated by refinement engine)
            let refinedText: String?
            if let utteranceID, let store = transcriptStore {
                refinedText = await store.utterances.first(where: { $0.id == utteranceID })?.refinedText
            } else {
                refinedText = baseRecord.refinedText
            }

            let enrichedRecord = SessionRecord(
                speaker: baseRecord.speaker,
                text: baseRecord.text,
                timestamp: baseRecord.timestamp,
                suggestions: latestSuggestion.map { [$0.text] },
                kbHits: latestSuggestion?.kbHits.map { $0.sourceFile },
                suggestionDecision: decision,
                surfacedSuggestionText: decision?.shouldSurface == true ? latestSuggestion?.text : nil,
                conversationStateSummary: summary?.isEmpty == false ? summary : nil,
                refinedText: refinedText
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

    /// Backfill refined text into the current session's JSONL from the in-memory TranscriptStore.
    func backfillRefinedText(from utterances: [Utterance]) {
        guard let currentFile else { return }

        try? fileHandle?.close()
        fileHandle = nil

        rewriteJSONLWithRefinedText(file: currentFile, utterances: utterances)

        fileHandle = try? FileHandle(forWritingTo: currentFile)
    }

    /// Backfill refined text into a past session's JSONL.
    func backfillRefinedText(sessionID: String, from utterances: [Utterance]) {
        rewriteJSONLWithRefinedText(file: jsonlURL(for: sessionID), utterances: utterances)
    }

    @discardableResult
    private func rewriteJSONLWithRefinedText(file: URL, utterances: [Utterance]) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var refinedLookup: [String: String] = [:]
        for utterance in utterances {
            guard let refined = utterance.refinedText else { continue }
            let key = "\(iso8601Formatter.string(from: utterance.timestamp))|\(utterance.speaker.rawValue)"
            refinedLookup[key] = refined
        }

        guard !refinedLookup.isEmpty else { return false }

        var updatedLines: [String] = []
        var anyUpdated = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  var record = try? decoder.decode(SessionRecord.self, from: data) else {
                updatedLines.append(line)
                continue
            }

            if record.refinedText == nil {
                let key = "\(iso8601Formatter.string(from: record.timestamp))|\(record.speaker.rawValue)"
                if let refined = refinedLookup[key] {
                    record = SessionRecord(
                        speaker: record.speaker,
                        text: record.text,
                        timestamp: record.timestamp,
                        suggestions: record.suggestions,
                        kbHits: record.kbHits,
                        suggestionDecision: record.suggestionDecision,
                        surfacedSuggestionText: record.surfacedSuggestionText,
                        conversationStateSummary: record.conversationStateSummary,
                        refinedText: refined
                    )
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

    // MARK: - Batch Audio Persistence

    /// Directory for a session's batch audio and metadata.
    private func sessionSubdirectory(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
    }

    /// Move/copy sealed CAF files into a per-session subdirectory and write timing anchors.
    func stashAudioForBatch(
        sessionID: String,
        micURL: URL?,
        sysURL: URL?,
        anchors: BatchAnchors
    ) {
        let fm = FileManager.default
        let dir = sessionSubdirectory(for: sessionID)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let src = micURL, fm.fileExists(atPath: src.path) {
            let dst = dir.appendingPathComponent("mic.caf")
            try? fm.moveItem(at: src, to: dst)
        }
        if let src = sysURL, fm.fileExists(atPath: src.path) {
            let dst = dir.appendingPathComponent("sys.caf")
            try? fm.moveItem(at: src, to: dst)
        }

        // Write batch-meta.json with timing anchors
        let meta = BatchMeta(
            micStartDate: anchors.micStartDate,
            sysStartDate: anchors.sysStartDate,
            micAnchors: anchors.micAnchors.map { .init(frame: $0.frame, date: $0.date) },
            sysAnchors: anchors.sysAnchors.map { .init(frame: $0.frame, date: $0.date) }
        )
        if let data = try? JSONEncoder.iso8601Encoder.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("batch-meta.json"), options: .atomic)
        }
    }

    /// Returns URLs for batch audio files, if they exist.
    func batchAudioURLs(sessionID: String) -> (mic: URL?, sys: URL?) {
        let fm = FileManager.default
        let dir = sessionSubdirectory(for: sessionID)
        let micURL = dir.appendingPathComponent("mic.caf")
        let sysURL = dir.appendingPathComponent("sys.caf")
        return (
            mic: fm.fileExists(atPath: micURL.path) ? micURL : nil,
            sys: fm.fileExists(atPath: sysURL.path) ? sysURL : nil
        )
    }

    /// Remove the session subdirectory (batch audio + metadata).
    func cleanupBatchAudio(sessionID: String) {
        let dir = sessionSubdirectory(for: sessionID)
        // Keep batch.jsonl if present by only removing audio files
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent("mic.caf"))
        try? fm.removeItem(at: dir.appendingPathComponent("sys.caf"))
        try? fm.removeItem(at: dir.appendingPathComponent("batch-meta.json"))

        // If only batch.jsonl remains or directory is empty, leave it
    }

    /// Load batch metadata for a session.
    func loadBatchMeta(sessionID: String) -> BatchMeta? {
        let metaURL = sessionSubdirectory(for: sessionID).appendingPathComponent("batch-meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BatchMeta.self, from: data)
    }

    /// Whether a batch transcript already exists for this session.
    func hasBatchTranscript(sessionID: String) -> Bool {
        let url = sessionSubdirectory(for: sessionID).appendingPathComponent("batch.jsonl")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Atomic write of batch transcript records.
    func writeBatchTranscript(sessionID: String, records: [SessionRecord]) {
        let dir = sessionSubdirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var payload = Data()
        for record in records {
            if let data = try? encoder.encode(record) {
                payload.append(data)
                payload.append(Data("\n".utf8))
            }
        }

        let finalURL = dir.appendingPathComponent("batch.jsonl")
        let tempURL = dir.appendingPathComponent("batch.jsonl.tmp")

        do {
            try payload.write(to: tempURL, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            diagLog("[SESSION-STORE] Failed to write batch transcript: \(error)")
        }
    }

    /// Remove orphaned batch audio files older than 24 hours.
    private static func cleanupOrphanedBatchAudio(in sessionsDirectory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 3600)

        for item in contents {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { continue }

            // Only look at session subdirectories (not .recently-deleted etc.)
            let name = item.lastPathComponent
            guard name.hasPrefix("session_") else { continue }

            let micURL = item.appendingPathComponent("mic.caf")
            let sysURL = item.appendingPathComponent("sys.caf")

            let hasMic = fm.fileExists(atPath: micURL.path)
            let hasSys = fm.fileExists(atPath: sysURL.path)

            guard hasMic || hasSys else { continue }

            if let modDate = values.contentModificationDate, modDate < cutoff {
                try? fm.removeItem(at: micURL)
                try? fm.removeItem(at: sysURL)
                try? fm.removeItem(at: item.appendingPathComponent("batch-meta.json"))
                diagLog("[SESSION-STORE] Cleaned up orphaned batch audio in \(name)")
            }
        }
    }

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
        currentSessionID = nil
    }

    /// Register a callback invoked once per session when a write error occurs.
    func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
    }

    private func reportWriteError(_ message: String) {
        print("SessionStore: \(message)")
        guard !hasReportedWriteError else { return }
        hasReportedWriteError = true
        onWriteError?(message)
    }

    // MARK: - Sidecar

    private func sidecarURL(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")
    }

    private func jsonlURL(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
    }

    func writeSidecar(_ sidecar: SessionSidecar) {
        let url = sidecarURL(for: sidecar.index.id)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sidecar)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("SessionStore: failed to write sidecar: \(error)")
        }
    }

    // MARK: - History

    func loadSessionIndex() -> [SessionIndex] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var indexMap: [String: SessionIndex] = [:]

        // Load from sidecar files
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".meta.json") {
            let stem = String(file.lastPathComponent.dropLast(".meta.json".count))
            guard let data = try? Data(contentsOf: file),
                  let sidecar = try? decoder.decode(SessionSidecar.self, from: data) else { continue }
            indexMap[stem] = sidecar.index
        }

        // Handle orphaned JSONL files
        for file in files where file.pathExtension == "jsonl" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard indexMap[stem] == nil else { continue }

            // Parse date from filename: session_YYYY-MM-DD_HH-mm-ss
            let datePart = stem.replacingOccurrences(of: "session_", with: "")
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let startDate = fmt.date(from: datePart) ?? Date()

            // Count lines for utteranceCount
            let lineCount = (try? String(contentsOf: file, encoding: .utf8))?
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .count ?? 0

            indexMap[stem] = SessionIndex(
                id: stem,
                startedAt: startDate,
                title: nil,
                utteranceCount: lineCount,
                hasNotes: false
            )
        }

        return indexMap.values.sorted { $0.startedAt > $1.startedAt }
    }

    func loadTranscript(sessionID: String) -> [SessionRecord] {
        // Prefer batch transcript when available
        let batchURL = sessionSubdirectory(for: sessionID)
            .appendingPathComponent("batch.jsonl")
        if FileManager.default.fileExists(atPath: batchURL.path),
           let content = try? String(contentsOf: batchURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        // Fallback to live JSONL
        return loadLiveTranscript(sessionID: sessionID)
    }

    /// Load the original live transcript (ignoring batch).
    func loadLiveTranscript(sessionID: String) -> [SessionRecord] {
        let url = jsonlURL(for: sessionID)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseJSONL(content)
    }

    private func parseJSONL(_ content: String) -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
    }

    func loadNotes(sessionID: String) -> EnhancedNotes? {
        let url = sidecarURL(for: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(SessionSidecar.self, from: data) else { return nil }
        return sidecar.notes
    }

    func saveNotes(sessionID: String, notes: EnhancedNotes) {
        let url = sidecarURL(for: sessionID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sidecar: SessionSidecar
        if let data = try? Data(contentsOf: url),
           let existing = try? decoder.decode(SessionSidecar.self, from: data) {
            sidecar = existing
        } else {
            // Recover metadata from JSONL filename and content
            let datePart = sessionID.replacingOccurrences(of: "session_", with: "")
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let startDate = fmt.date(from: datePart) ?? Date()

            let jsonlFile = jsonlURL(for: sessionID)
            let lineCount = (try? String(contentsOf: jsonlFile, encoding: .utf8))?
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .count ?? 0

            sidecar = SessionSidecar(
                index: SessionIndex(
                    id: sessionID,
                    startedAt: startDate,
                    utteranceCount: lineCount,
                    hasNotes: false
                ),
                notes: nil
            )
        }

        sidecar.notes = notes
        let idx = sidecar.index
        sidecar = SessionSidecar(
            index: SessionIndex(
                id: idx.id,
                startedAt: idx.startedAt,
                endedAt: idx.endedAt,
                templateSnapshot: idx.templateSnapshot,
                title: idx.title,
                utteranceCount: idx.utteranceCount,
                hasNotes: true,
                meetingApp: idx.meetingApp,
                engine: idx.engine
            ),
            notes: notes
        )

        writeSidecar(sidecar)
    }

    func deleteSession(sessionID: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: jsonlURL(for: sessionID))
        try? fm.removeItem(at: sidecarURL(for: sessionID))
        // Remove batch audio subdirectory if present
        let subdir = sessionSubdirectory(for: sessionID)
        if fm.fileExists(atPath: subdir.path) {
            try? fm.removeItem(at: subdir)
        }
    }

    func renameSession(sessionID: String, newTitle: String) {
        let url = sidecarURL(for: sessionID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: url),
              var sidecar = try? decoder.decode(SessionSidecar.self, from: data) else { return }

        let idx = sidecar.index
        sidecar = SessionSidecar(
            index: SessionIndex(
                id: idx.id,
                startedAt: idx.startedAt,
                endedAt: idx.endedAt,
                templateSnapshot: idx.templateSnapshot,
                title: newTitle.isEmpty ? nil : newTitle,
                utteranceCount: idx.utteranceCount,
                hasNotes: idx.hasNotes,
                meetingApp: idx.meetingApp,
                engine: idx.engine
            ),
            notes: sidecar.notes
        )

        writeSidecar(sidecar)
    }

    var sessionsDirectoryURL: URL { sessionsDirectory }

    func seedSession(
        id: String,
        records: [SessionRecord],
        startedAt: Date,
        endedAt: Date? = nil,
        templateSnapshot: TemplateSnapshot? = nil,
        title: String? = nil,
        notes: EnhancedNotes? = nil
    ) {
        let jsonl = jsonlURL(for: id)
        let sidecar = SessionSidecar(
            index: SessionIndex(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                templateSnapshot: templateSnapshot,
                title: title,
                utteranceCount: records.count,
                hasNotes: notes != nil
            ),
            notes: notes
        )

        do {
            var payload = Data()
            for record in records {
                payload.append(try encoder.encode(record))
                payload.append(Data("\n".utf8))
            }
            try payload.write(to: jsonl, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonl.path)
        } catch {
            print("SessionStore: failed to seed transcript: \(error)")
        }

        writeSidecar(sidecar)
    }

    // MARK: - Recently Deleted

    private var recentlyDeletedDirectory: URL {
        sessionsDirectory.appendingPathComponent(".recently-deleted", isDirectory: true)
    }

    /// Move a session's JSONL and sidecar files to .recently-deleted/.
    func moveToRecentlyDeleted(sessionID: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: recentlyDeletedDirectory, withIntermediateDirectories: true)

        let jsonl = jsonlURL(for: sessionID)
        let sidecar = sidecarURL(for: sessionID)

        if fm.fileExists(atPath: jsonl.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(jsonl.lastPathComponent)
            try? fm.moveItem(at: jsonl, to: dest)
        }
        if fm.fileExists(atPath: sidecar.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(sidecar.lastPathComponent)
            try? fm.moveItem(at: sidecar, to: dest)
        }
    }

    /// Permanently remove all files in the .recently-deleted/ folder.
    func purgeRecentlyDeleted() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recentlyDeletedDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }
}

// MARK: - Batch Transcription Support Types

/// Timing anchor data passed from AudioRecorder to SessionStore.
struct BatchAnchors: Sendable {
    let micStartDate: Date?
    let sysStartDate: Date?
    let micAnchors: [(frame: Int64, date: Date)]
    let sysAnchors: [(frame: Int64, date: Date)]
}

/// Codable batch metadata persisted as batch-meta.json.
struct BatchMeta: Codable, Sendable {
    let micStartDate: Date?
    let sysStartDate: Date?
    let micAnchors: [TimingAnchor]
    let sysAnchors: [TimingAnchor]

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
