import Foundation

/// Persists session transcripts as JSONL files.
actor SessionStore {
    private let sessionsDirectory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private let encoder = JSONEncoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("Gelato/sessions", isDirectory: true)

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
    }

    func startSession() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionID = "session_\(formatter.string(from: Date()))"
        let sessionDirectory = SessionPaths.sessionDirectory(in: sessionsDirectory, sessionID: sessionID)
        let transcriptURL = SessionPaths.transcriptURL(in: sessionsDirectory, sessionID: sessionID)

        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        currentFile = transcriptURL

        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: transcriptURL)
    }

    func appendRecord(_ record: SessionRecord) {
        guard let fileHandle else { return }

        do {
            // Throwing FileHandle APIs — the legacy seekToEndOfFile()/write(_:)
            // raise uncatchable NSExceptions on write failure (e.g. disk full).
            let data = try encoder.encode(record)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            try fileHandle.write(contentsOf: Data("\n".utf8))
        } catch {
            print("SessionStore: failed to write record: \(error)")
        }
    }

    func replaceRecords(_ records: [SessionRecord]) {
        guard let currentFile else { return }

        do {
            let data = try records.reduce(into: Data()) { partialResult, record in
                partialResult.append(try encoder.encode(record))
                partialResult.append(Data("\n".utf8))
            }
            try data.write(to: currentFile, options: .atomic)
            fileHandle = try? FileHandle(forWritingTo: currentFile)
        } catch {
            print("SessionStore: failed to replace records: \(error)")
        }
    }

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
    }

    /// URL of the current session file (nil if no session is active).
    var currentSessionURL: URL? { currentFile }

    var sessionsDirectoryURL: URL { sessionsDirectory }
}
