import Foundation

/// Auto-saves transcripts as plain text files to a configurable folder.
actor TranscriptLogger {
    private var directory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private var sessionHeader: String = ""

    /// Called (once) when a write error occurs during the session.
    private var onWriteError: (@Sendable (String) -> Void)?
    private var hasReportedWriteError = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OpenOats", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: self.directory)
    }

    func updateDirectory(_ url: URL) {
        self.directory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: url)
    }

    /// Place a .metadata_never_index sentinel so Spotlight skips this directory.
    private static func dropMetadataNeverIndex(in directory: URL) {
        let sentinel = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    func startSession() {
        let now = Date()
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let filename = "\(fileFmt.string(from: now)).txt"
        let file = directory.appendingPathComponent(filename)
        currentFile = file
        hasReportedWriteError = false

        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        sessionHeader = "OpenOats - \(headerFmt.string(from: now))\n\n"

        FileManager.default.createFile(atPath: file.path, contents: sessionHeader.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
        do {
            fileHandle = try FileHandle(forWritingTo: file)
            fileHandle?.seekToEndOfFile()
        } catch {
            reportWriteError("Failed to open transcript file: \(error.localizedDescription)")
        }
    }

    func append(speaker: String, text: String, timestamp: Date, refinedText: String? = nil) {
        guard let fileHandle else {
            reportWriteError("No file handle available for transcript write")
            return
        }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let displayText = refinedText ?? text
        let line = "[\(timeFmt.string(from: timestamp))] \(speaker): \(displayText)\n"
        if let data = line.data(using: .utf8) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }
    }

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
    }

    /// Register a callback invoked once per session when a write error occurs.
    func setWriteErrorHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onWriteError = handler
    }

    private func reportWriteError(_ message: String) {
        print("TranscriptLogger: \(message)")
        guard !hasReportedWriteError else { return }
        hasReportedWriteError = true
        onWriteError?(message)
    }
}
