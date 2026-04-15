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
        self.init(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled Event",
            startDate: event.startDate,
            endDate: event.endDate,
            organizer: event.organizer?.name,
            participants: (event.attendees ?? []).map { Participant(from: $0) },
            isOnlineMeeting: event.url != nil || Self.looksLikeOnlineMeeting(event),
            meetingURL: event.url
        )
    }

    private static func looksLikeOnlineMeeting(_ event: EKEvent) -> Bool {
        let notes = (event.notes ?? "").lowercased()
        let location = (event.location ?? "").lowercased()
        let keywords = ["zoom.us", "teams.microsoft", "meet.google", "facetime", "webex"]
        return keywords.contains { notes.contains($0) || location.contains($0) }
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
