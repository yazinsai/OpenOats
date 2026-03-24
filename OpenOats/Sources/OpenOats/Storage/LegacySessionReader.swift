import Foundation

/// Reads sessions stored in the pre-SessionRepository flat layout:
///
/// ```
/// sessions/<id>.jsonl          (live transcript)
/// sessions/<id>.meta.json      (sidecar with index + notes)
/// sessions/<id>/batch.jsonl    (batch transcript, optional)
/// sessions/<id>/mic.caf        (batch audio, optional)
/// sessions/<id>/sys.caf        (batch audio, optional)
/// sessions/<id>/batch-meta.json (batch anchors, optional)
/// ```
///
/// This enum is stateless: all methods are static and take the sessions directory.
enum LegacySessionReader {

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Listing

    /// List legacy sessions that don't have a canonical `session.json`.
    static func listSessions(
        sessionsDirectory: URL,
        excludingIDs canonicalIDs: Set<String>
    ) -> [SessionIndex] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var indexMap: [String: SessionIndex] = [:]

        // Load from sidecar files
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".meta.json") {
            let stem = String(file.lastPathComponent.dropLast(".meta.json".count))
            guard !canonicalIDs.contains(stem) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let sidecar = try? decoder.decode(SessionSidecar.self, from: data) else { continue }
            indexMap[stem] = sidecar.index
        }

        // Handle orphaned JSONL files (no sidecar, no canonical)
        for file in files where file.pathExtension == "jsonl" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard !canonicalIDs.contains(stem), indexMap[stem] == nil else { continue }

            let datePart = stem.replacingOccurrences(of: "session_", with: "")
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let startDate = fmt.date(from: datePart) ?? Date()

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

        return Array(indexMap.values)
    }

    // MARK: - Loading

    static func loadSession(id: String, sessionsDirectory: URL) -> SessionDetail {
        let index = loadIndex(sessionID: id, sessionsDirectory: sessionsDirectory)
        let transcript = loadTranscript(sessionID: id, sessionsDirectory: sessionsDirectory)
        let liveTranscript = loadLiveTranscript(sessionID: id, sessionsDirectory: sessionsDirectory)
        let notes = loadNotes(sessionID: id, sessionsDirectory: sessionsDirectory)

        return SessionDetail(
            index: index,
            transcript: transcript,
            liveTranscript: liveTranscript,
            notes: notes,
            notesMeta: nil
        )
    }

    static func loadIndex(sessionID: String, sessionsDirectory: URL) -> SessionIndex {
        let sidecarURL = sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let sidecar = try? decoder.decode(SessionSidecar.self, from: data) {
            return sidecar.index
        }

        // Reconstruct from filename
        let datePart = sessionID.replacingOccurrences(of: "session_", with: "")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let startDate = fmt.date(from: datePart) ?? Date()

        let jsonlFile = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        let lineCount = (try? String(contentsOf: jsonlFile, encoding: .utf8))?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .count ?? 0

        return SessionIndex(
            id: sessionID,
            startedAt: startDate,
            title: nil,
            utteranceCount: lineCount,
            hasNotes: false
        )
    }

    static func loadTranscript(sessionID: String, sessionsDirectory: URL) -> [SessionRecord] {
        // Prefer batch transcript
        let batchURL = sessionsDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("batch.jsonl")
        if FileManager.default.fileExists(atPath: batchURL.path),
           let content = try? String(contentsOf: batchURL, encoding: .utf8) {
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }

        return loadLiveTranscript(sessionID: sessionID, sessionsDirectory: sessionsDirectory)
    }

    static func loadLiveTranscript(sessionID: String, sessionsDirectory: URL) -> [SessionRecord] {
        let url = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseJSONL(content)
    }

    static func loadNotes(sessionID: String, sessionsDirectory: URL) -> EnhancedNotes? {
        let url = sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? decoder.decode(SessionSidecar.self, from: data) else { return nil }
        return sidecar.notes
    }

    // MARK: - Mutations

    static func renameSession(sessionID: String, newTitle: String, sessionsDirectory: URL) {
        let url = sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")
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
                engine: idx.engine,
                tags: idx.tags
            ),
            notes: sidecar.notes
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(sidecar) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    static func deleteSession(sessionID: String, sessionsDirectory: URL) {
        let fm = FileManager.default
        let jsonlURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        let sidecarURL = sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")
        try? fm.removeItem(at: jsonlURL)
        try? fm.removeItem(at: sidecarURL)

        // Remove legacy subdirectory (batch audio)
        let subdir = sessionsDirectory.appendingPathComponent(sessionID, isDirectory: true)
        // Don't remove if it's now a canonical session directory with session.json
        let sessionJSON = subdir.appendingPathComponent("session.json")
        if fm.fileExists(atPath: subdir.path) && !fm.fileExists(atPath: sessionJSON.path) {
            try? fm.removeItem(at: subdir)
        }
    }

    static func moveToRecentlyDeleted(
        sessionID: String,
        sessionsDirectory: URL,
        recentlyDeletedDirectory: URL
    ) {
        let fm = FileManager.default
        let jsonlURL = sessionsDirectory.appendingPathComponent("\(sessionID).jsonl")
        let sidecarURL = sessionsDirectory.appendingPathComponent("\(sessionID).meta.json")

        if fm.fileExists(atPath: jsonlURL.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(jsonlURL.lastPathComponent)
            try? fm.moveItem(at: jsonlURL, to: dest)
        }
        if fm.fileExists(atPath: sidecarURL.path) {
            let dest = recentlyDeletedDirectory.appendingPathComponent(sidecarURL.lastPathComponent)
            try? fm.moveItem(at: sidecarURL, to: dest)
        }
    }

    // MARK: - Helpers

    private static func parseJSONL(_ content: String) -> [SessionRecord] {
        content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
    }
}
