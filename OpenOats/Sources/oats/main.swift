import Foundation
import OatsCapture
import OatsCore
import OatsOnDevice

let usage = """
usage: oats transcribe <audio> [<system-audio>] [--language <code>] > meeting.md
       oats process <meeting-id>
       oats notes <meeting>
       oats record [--fake-source] [--seconds <n>] [--notes-folder <dir>]
       oats recover [--notes-folder <dir>]
"""

let settings = SettingsStore(makers: .withOnDevice { p in
    FileHandle.standardError.write(Data(String(format: "\rDownloading the transcription model… %3.0f%%", p * 100).utf8))
})

func run(_ folder: MeetingFolder, _ options: ProcessingOptions) async throws -> String {
    let status = try await Processing.run(folder, options: options)
    if let error = status.lastError { throw CLIError(error) }
    return status.meetingFile ?? ""
}

/// Saved settings, with `--notes-folder` applied. `OATS_FAKE_TRANSCRIPTION=<seconds>` (tests) swaps in the fake
/// Transcription backend and skips Notes.
func recordingOptions(_ args: inout [String]) -> ProcessingOptions {
    var options = settings.processingOptions()
    if let i = args.firstIndex(of: "--notes-folder"), i + 1 < args.count {
        options.notesFolder = URL(fileURLWithPath: args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    if let delay = ProcessInfo.processInfo.environment["OATS_FAKE_TRANSCRIPTION"].flatMap(Double.init) {
        options.transcription = FakeTranscription(delay: delay)
        options.notes = nil
    }
    return options
}

var args = Array(CommandLine.arguments.dropFirst())
do {
    switch (args.first, args.count) {
    case ("transcribe", 2...5):
        // A throwaway Meeting: import, process with the saved backends, print the Meeting file, delete everything.
        args.removeFirst()
        var language = settings.load().meetingLanguage
        if let i = args.firstIndex(of: "--language"), i + 1 < args.count {
            language = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        guard (1...2).contains(args.count) else { throw CLIError(usage) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let folder = try MeetingStore(root: temp).importAudio(args.map { URL(fileURLWithPath: $0) }, language: language)
        var options = settings.processingOptions()
        options.notesFolder = temp
        options.keepAudio = false
        print(try String(contentsOfFile: try await run(folder, options), encoding: .utf8), terminator: "")
    case ("process", 2):
        // Retry an unfinished Meeting, or re-process a done one (needs its kept audio). Prints the Meeting file path.
        guard let folder = meetingStore.folder(id: args[1]) else { throw CLIError("No Meeting \(args[1]).") }
        if try folder.readStatus().state == .done { try Processing.prepareReprocess(folder) }
        print(try await run(folder, settings.processingOptions()))
    case ("notes", 2): print(try await notesCommand(args[1]), terminator: "")
    case ("recover", _):
        args.removeFirst()
        try await recoverCommand(options: recordingOptions(&args))
    case ("record", _):
        // Mic and system audio, or with --fake-source a deterministic test tone.
        args.removeFirst()
        let options = recordingOptions(&args)
        let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        let source: any CaptureSource = args.contains("--fake-source") ? ToneSource() : LiveCapture(onProblem: log)
        try await recordCommand(source: source, seconds: seconds, options: options)
    default:
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("oats: \(error.localizedDescription)\n".utf8))
    exit(1)
}
