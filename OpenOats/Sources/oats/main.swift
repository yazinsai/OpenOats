import Foundation
import OatsCore
import OatsOnDevice

let usage = """
usage: oats transcribe <audio> [<system-audio>] [--language <code>] > meeting.md
       oats process <meeting-id> [--notes-folder <dir>]
       oats notes <meeting>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("oats: \(message)\n".utf8))
    exit(1)
}

/// Removes `--name value` from `args` and returns the value.
func option(_ name: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

func backend(language: String?) -> OnDeviceTranscription {
    OnDeviceTranscription(language: language) { p in
        FileHandle.standardError.write(Data(String(format: "\rDownloading model… %3.0f%%", p * 100).utf8))
    }
}

func run(_ folder: MeetingFolder, options: ProcessingOptions) async throws -> URL {
    let status = try await Processing.run(folder, options: options)
    if let error = status.lastError { fail(error) }
    return URL(fileURLWithPath: status.meetingFile!)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "" : args.removeFirst()
do {
    switch command {
    case "transcribe":
        // A throwaway Meeting: import, process, print the Meeting file, delete everything.
        let language = option("language", &args) ?? Locale.current.language.languageCode?.identifier
        guard (1...2).contains(args.count) else { fail(usage) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let folder = try MeetingStore(root: temp).importAudio(args.map { URL(fileURLWithPath: $0) }, language: language)
        let options = ProcessingOptions(transcription: backend(language: language), notesFolder: temp, keepAudio: false)
        print(try String(contentsOf: try await run(folder, options: options), encoding: .utf8), terminator: "")
    case "process":
        // Retry an unfinished Meeting, or re-process a done one (needs its kept audio).
        let notesFolder = option("notes-folder", &args)
        guard args.count == 1, let folder = MeetingStore().folder(id: args[0]) else { fail("no Meeting \(args.first ?? "")") }
        let status = try folder.readStatus()
        if status.state == .done { try Processing.prepareReprocess(folder) }
        let target = notesFolder.map { URL(fileURLWithPath: $0) }
            ?? status.meetingFile.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        print(try await run(folder, options: ProcessingOptions(transcription: backend(language: status.language), notesFolder: target)).path)
    case "notes" where args.count == 1:
        fail("no Notes backend (the Notes step arrives with #755)")
    default:
        fail(usage)
    }
} catch {
    fail(error.localizedDescription)
}
