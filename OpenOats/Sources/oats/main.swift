import Foundation
import OatsCore

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch (args.first, args.count) {
    case ("notes", 2): print(try await notesCommand(args[1]), terminator: "")
    default:
        FileHandle.standardError.write(Data("usage: oats notes <meeting>\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("oats: \(error.localizedDescription)\n".utf8))
    exit(1)
}
