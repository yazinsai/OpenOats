import Foundation

// MARK: - Meeting App Detection

/// A running application that may host meetings.
struct MeetingApp: Sendable, Hashable, Codable {
    let bundleID: String
    let name: String
}

/// A single entry in the list of known meeting apps.
struct MeetingAppEntry: Sendable, Hashable, Codable {
    let bundleID: String
    let displayName: String
}

// MARK: - Detection Signal

/// Describes why the system believes a meeting started or ended.
enum DetectionSignal: Sendable, Hashable, Codable {
    /// User pressed Start manually.
    case manual
    /// A known meeting app was detected running.
    case appLaunched(MeetingApp)
    /// A calendar event started.
    case calendarEvent(CalendarEvent)
    /// Audio activity was detected from a meeting source.
    case audioActivity
    /// A camera was activated, suggesting a video call.
    case cameraActivated
}

// MARK: - Detection Context

/// Aggregated context about an active or pending meeting.
struct DetectionContext: Sendable, Equatable, Codable {
    let signal: DetectionSignal
    let detectedAt: Date
    let meetingApp: MeetingApp?
    let calendarEvent: CalendarEvent?
}

// MARK: - Calendar Integration

/// Minimal representation of a calendar event relevant to meeting detection.
struct CalendarEvent: Sendable, Hashable, Codable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let organizer: String?
    let participants: [Participant]
    let isOnlineMeeting: Bool
    let meetingURL: URL?
}

/// A meeting participant from a calendar event.
struct Participant: Sendable, Hashable, Codable {
    let name: String?
    let email: String?
}

extension Participant {
    var displayName: String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        return nil
    }
}

extension CalendarEvent {
    var invitedParticipantDisplayNames: [String] {
        var results: [String] = []
        var seen: Set<String> = []

        for participant in participants {
            guard let displayName = participant.displayName else { continue }
            let key = participant.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? displayName.lowercased()
            if seen.insert(key).inserted {
                results.append(displayName)
            }
        }

        return results
    }
}

// MARK: - Meeting Metadata

/// Metadata assembled during a meeting session (detection context + calendar info).
struct MeetingMetadata: Sendable, Equatable, Codable {
    let detectionContext: DetectionContext?
    let calendarEvent: CalendarEvent?
    let title: String?
    let startedAt: Date
    var endedAt: Date?

    static func manual(calendarEvent: CalendarEvent? = nil) -> MeetingMetadata {
        let now = Date()
        return MeetingMetadata(
            detectionContext: DetectionContext(
                signal: calendarEvent.map { .calendarEvent($0) } ?? .manual,
                detectedAt: now,
                meetingApp: nil,
                calendarEvent: calendarEvent
            ),
            calendarEvent: calendarEvent,
            title: calendarEvent?.title,
            startedAt: now, endedAt: nil
        )
    }
}
