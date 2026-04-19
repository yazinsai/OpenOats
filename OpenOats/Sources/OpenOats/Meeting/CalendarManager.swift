import EventKit
import Foundation

/// Wraps EKEventStore to look up calendar events overlapping the current time.
/// All access is gated behind the `calendarIntegrationEnabled` setting — the app
/// only requests calendar permission when the user explicitly enables the feature.
@MainActor
@Observable
final class CalendarManager {
    @ObservationIgnored private let store = EKEventStore()

    enum AccessState {
        case notDetermined
        case authorized
        case denied
    }

    /// Current authorization status, observed at init and after requesting access.
    private(set) var accessState: AccessState

    init() {
        self.accessState = Self.currentAccessState()
    }

    // MARK: - Authorization

    /// Request calendar access. Returns true if authorized.
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            accessState = granted ? .authorized : .denied
            return granted
        } catch {
            accessState = .denied
            return false
        }
    }

    // MARK: - Event Lookup

    /// Find the calendar event that best overlaps the given date (typically now).
    /// Returns nil if no event is found or access is not authorized.
    func currentEvent(at date: Date = Date()) -> CalendarEvent? {
        guard accessState == .authorized else { return nil }

        // Look for events in a window: started up to 15 min ago through 15 min from now
        let windowStart = date.addingTimeInterval(-15 * 60)
        let windowEnd = date.addingTimeInterval(15 * 60)

        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        let events = store.events(matching: predicate)

        // Prefer the event whose start is closest to now, breaking ties by duration
        let best = events
            .filter { !$0.isAllDay }
            .min { a, b in
                let distA = abs(a.startDate.timeIntervalSince(date))
                let distB = abs(b.startDate.timeIntervalSince(date))
                if distA != distB { return distA < distB }
                return a.startDate < b.startDate
            }

        guard let best else { return nil }
        return CalendarEvent(from: best)
    }

    /// Upcoming calendar events starting within the given time window, ordered by start date.
    /// Returns an empty array if access is not authorized.
    func upcomingEvents(
        from date: Date = Date(),
        within window: TimeInterval = 12 * 60 * 60,
        limit: Int = 5
    ) -> [CalendarEvent] {
        guard accessState == .authorized else { return [] }

        let windowEnd = date.addingTimeInterval(window)
        let predicate = store.predicateForEvents(
            withStart: date,
            end: windowEnd,
            calendars: nil
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= date }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        return events.map { CalendarEvent(from: $0) }
    }

    // MARK: - Helpers

    private static func currentAccessState() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }
}

// MARK: - EKEvent → CalendarEvent

extension CalendarEvent {
    init(from event: EKEvent) {
        let meetingURL = CalendarMeetingLinkResolver.meetingURL(
            rawURL: event.url,
            notes: event.notes,
            location: event.location
        )
        self.init(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled Event",
            startDate: event.startDate,
            endDate: event.endDate,
            organizer: event.organizer?.name,
            participants: (event.attendees ?? []).map { Participant(from: $0) },
            isOnlineMeeting: CalendarMeetingLinkResolver.isOnlineMeeting(
                rawURL: event.url,
                notes: event.notes,
                location: event.location
            ),
            meetingURL: meetingURL
        )
    }
}

extension Participant {
    init(from attendee: EKParticipant) {
        self.init(
            name: attendee.name,
            email: attendee.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
        )
    }
}

enum CalendarMeetingLinkResolver {
    private static let hostHints = [
        "zoom.us",
        "teams.microsoft",
        "teams.live",
        "meet.google",
        "webex",
        "whereby.com",
        "around.co",
        "jitsi",
        "chime.aws",
        "gotomeeting",
        "bluejeans",
        "facetime",
    ]

    private static let textHints = [
        "zoom",
        "teams",
        "meet",
        "webex",
        "facetime",
        "join",
    ]

    static func meetingURL(rawURL: URL?, notes: String?, location: String?) -> URL? {
        if let rawURL {
            return rawURL
        }

        let candidates = detectedURLs(in: notes) + detectedURLs(in: location)

        if let preferred = candidates.first(where: isLikelyMeetingURL) {
            return preferred
        }

        return nil
    }

    static func isOnlineMeeting(rawURL: URL?, notes: String?, location: String?) -> Bool {
        if meetingURL(rawURL: rawURL, notes: notes, location: location) != nil {
            return true
        }

        let haystack = "\(notes ?? "")\n\(location ?? "")".lowercased()
        return textHints.contains { haystack.contains($0) }
    }

    private static func detectedURLs(in text: String?) -> [URL] {
        guard let text, !text.isEmpty else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let url = match.url else { return nil }
            guard let scheme = url.scheme?.lowercased() else { return nil }
            guard scheme == "http" || scheme == "https" || scheme == "facetime" else {
                return nil
            }
            return url
        }
    }

    private static func isLikelyMeetingURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "facetime" {
            return true
        }

        let host = url.host?.lowercased() ?? ""
        if hostHints.contains(where: host.contains) {
            return true
        }

        let absolute = url.absoluteString.lowercased()
        return textHints.contains(where: absolute.contains)
    }
}
