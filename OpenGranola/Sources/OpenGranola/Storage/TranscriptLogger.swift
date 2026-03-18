import Foundation

/// Auto-saves transcripts as plain text files to ~/Documents/OpenOats/
actor TranscriptLogger {
    private let directory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private var sessionHeader: String = ""

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OpenOats", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func startSession() {
        let now = Date()
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let filename = "\(fileFmt.string(from: now)).txt"
        currentFile = directory.appendingPathComponent(filename)

        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        sessionHeader = "OpenOats - \(headerFmt.string(from: now))\n\n"

        FileManager.default.createFile(atPath: currentFile!.path, contents: sessionHeader.data(using: .utf8))
        fileHandle = try? FileHandle(forWritingTo: currentFile!)
        fileHandle?.seekToEndOfFile()
    }

    func append(speaker: String, text: String, timestamp: Date) {
        guard let fileHandle else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let line = "[\(timeFmt.string(from: timestamp))] \(speaker): \(text)\n"
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
}
