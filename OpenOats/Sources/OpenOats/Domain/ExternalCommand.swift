import Foundation

// MARK: - External Command

/// A command issued to the app from outside (deep link, menu bar, global hotkey).
enum ExternalCommand: Equatable {
    case startSession(calendarEvent: CalendarEvent? = nil, scratchpadSeed: String? = nil)
    case stopSession
    case openNotes(sessionID: String?)
}

/// A pending external command with a stable identity, so consumers can
/// mark it as handled without racing on the value itself.
struct ExternalCommandRequest: Identifiable, Equatable {
    let id: UUID
    let command: ExternalCommand

    init(command: ExternalCommand) {
        self.id = UUID()
        self.command = command
    }
}
