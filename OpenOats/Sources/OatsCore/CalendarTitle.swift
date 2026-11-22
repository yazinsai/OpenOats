import Foundation

/// A calendar event as the title lookup sees it. The app reads these from EventKit, leaving out all-day, cancelled
/// and declined events.
public struct CalendarEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    /// Other attendees or a call link: a meeting, not a personal block such as "Focus" or "Lunch".
    public var withOthers: Bool

    public init(title: String, start: Date, end: Date, withOthers: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.withOthers = withOthers
    }

    /// The title of the meeting a recording was part of: the event with others it overlaps most, the shorter one on a
    /// tie (a meeting inside an all-hands block). The overlap must be at least a quarter of the shorter of the two,
    /// so a recording that started in the last minutes of the previous meeting isn't named after it. nil when none.
    public static func title(for recording: DateInterval, in events: [CalendarEvent]) -> String? {
        let candidates = events.compactMap { event -> (CalendarEvent, TimeInterval)? in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard event.withOthers, !title.isEmpty, event.end > event.start else { return nil }
            let overlap = min(event.end, recording.end).timeIntervalSince(max(event.start, recording.start))
            let shorter = min(event.end.timeIntervalSince(event.start), recording.duration)
            guard overlap > 0, overlap >= shorter / 4 else { return nil }
            return (CalendarEvent(title: title, start: event.start, end: event.end, withOthers: true), overlap)
        }
        return candidates.min { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let (la, lb) = (a.0.end.timeIntervalSince(a.0.start), b.0.end.timeIntervalSince(b.0.start))
            return la != lb ? la < lb : a.0.start < b.0.start
        }?.0.title
    }
}
