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

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("OpenOats/sessions", isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
    }

    func startSession(templateID: UUID? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "session_\(formatter.string(from: Date()))"
        currentSessionID = stem
        let filename = "\(stem).jsonl"
        currentFile = sessionsDirectory.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: currentFile!.path, contents: nil)
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

            let enrichedRecord = SessionRecord(
                speaker: baseRecord.speaker,
                text: baseRecord.text,
                timestamp: baseRecord.timestamp,
                suggestions: latestSuggestion.map { [$0.text] },
                kbHits: latestSuggestion?.kbHits.map { $0.sourceFile },
                suggestionDecision: decision,
                surfacedSuggestionText: decision?.shouldSurface == true ? latestSuggestion?.text : nil,
                conversationStateSummary: summary?.isEmpty == false ? summary : nil
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

    var sessionsDirectoryURL: URL { sessionsDirectory }
}
