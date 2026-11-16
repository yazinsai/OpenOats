import Foundation
import OatsCore

/// `oats notes <meeting id or folder>`: writes the Notes again with the saved Notes backend and prints the Meeting file.
func notesCommand(_ meeting: String) async throws -> String {
    let folder = MeetingStore().folder(id: meeting) ?? MeetingFolder(url: URL(fileURLWithPath: meeting))
    let store = SettingsStore()
    guard store.load().notes.type != .none else { throw CLIError("No Notes backend is set. Choose one in Settings > AI.") }
    try Processing.prepareNotes(folder)
    let status = try await Processing.run(folder, options: store.processingOptions())
    if let error = status.lastError { throw CLIError(error) }
    return try String(contentsOfFile: status.meetingFile ?? "", encoding: .utf8)
}

struct CLIError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
