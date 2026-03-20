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
        let filename = "\(stem).jsonl"
        currentFile = sessionsDirectory.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: currentFile!.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        fileHandle = try? FileHandle(forWritingTo: currentFile!)
    }

    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle else { return }

        do {
            let data = try encoder.encode(record)
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.write("\n".data(using: .utf8)!)
        } catch {
            print("SessionStore: failed to write record: \(error)")
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

        let updated = rewriteJSONLWithRefinedText(file: currentFile, utterances: utterances)
        _ = updated

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

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
        currentSessionID = nil
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
        let url = jsonlURL(for: sessionID)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

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
                hasNotes: true
            ),
            notes: notes
        )

        writeSidecar(sidecar)
    }

    func deleteSession(sessionID: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: jsonlURL(for: sessionID))
        try? fm.removeItem(at: sidecarURL(for: sessionID))
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
                hasNotes: idx.hasNotes
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
