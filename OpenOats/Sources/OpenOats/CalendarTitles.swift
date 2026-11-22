import EventKit
import OatsCore

/// Names a Meeting after the calendar event it happened in. Optional: only with the setting on and full calendar
/// access, read on this Mac, never sent anywhere. Access is asked for only when the user turns the setting on.
enum CalendarTitles {
    /// Re-read every time: the user can change it in System Settings at any moment, and a denial is never asked again.
    static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var denied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// Shows the system prompt the first time; afterwards returns the saved answer.
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// The event title for a recording, or nil. A fresh store each time, so calendars added since are seen.
    static func title(for recording: DateInterval) -> String? {
        guard allowed, recording.duration > 0 else { return nil }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: recording.start, end: recording.end, calendars: nil))
        return CalendarEvent.title(for: recording, in: events.compactMap(CalendarEvent.init))
    }
}

extension CalendarEvent {
    /// nil for events that can't be the meeting: all-day, cancelled, or declined.
    init?(_ event: EKEvent) {
        let me = event.attendees?.first(where: \.isCurrentUser)
        guard !event.isAllDay, event.status != .canceled, me?.participantStatus != .declined else { return nil }
        let others = event.attendees?.contains { !$0.isCurrentUser } ?? false
        let text = [event.location, event.notes].compactMap { $0?.lowercased() }.joined(separator: " ")
        let link = event.url != nil || Self.callHosts.contains { text.contains($0) }
        self.init(title: event.title ?? "", start: event.startDate, end: event.endDate, withOthers: others || link)
    }

    private static let callHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com",
                                    "whereby.com", "around.co", "facetime.apple.com"]
}
