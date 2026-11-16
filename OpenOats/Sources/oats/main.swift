import Foundation
import OatsCore

/// Removes `--name value` from `args` and returns the value.
func option(_ name: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "" : args.removeFirst()
do {
    switch command {
    case "notes" where args.count == 1: print(try await notesCommand(args[0]), terminator: "")
    case "record", "recover":
        let notesFolder = URL(fileURLWithPath: option("notes-folder", &args) ?? FileManager.default.currentDirectoryPath)
        let fake = ProcessInfo.processInfo.environment["OATS_FAKE_TRANSCRIPTION"].flatMap(Double.init)
        guard let fake else { throw CLIError("on-device transcription arrives with #754") }
        let asr = FakeTranscription(delay: fake)
        if command == "recover" { try await recoverCommand(transcription: asr, notesFolder: notesFolder); break }
        guard args.contains("--fake-source") else { throw CLIError("live capture arrives with #760; use --fake-source") }
        try await recordCommand(seconds: option("seconds", &args).flatMap(Double.init), transcription: asr, notesFolder: notesFolder)
    default:
        FileHandle.standardError.write(Data("usage: oats notes <meeting> | record --fake-source [--seconds N] | recover\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("oats: \(error.localizedDescription)\n".utf8))
    exit(1)
}
