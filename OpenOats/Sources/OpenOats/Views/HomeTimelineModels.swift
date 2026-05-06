import Foundation

enum HomeTimelineEntry: Identifiable, Equatable {
    case calendar(CalendarEvent)
    case savedSession(SessionIndex)

    var id: String {
        switch self {
        case .calendar(let event):
            return "calendar:\(event.id)"
        case .savedSession(let session):
            return "session:\(session.id)"
        }
    }

    var startDate: Date {
        switch self {
        case .calendar(let event):
            return event.startDate
        case .savedSession(let session):
            return session.startedAt
        }
    }
}

struct HomeTimelineDayGroup: Identifiable, Equatable {
    let date: Date
    let entries: [HomeTimelineEntry]

    var id: Date { date }

    var sectionTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return "\(Self.weekdayFormatter.string(from: date)), \(Self.dayNumberFormatter.string(from: date)) \(Self.monthFormatter.string(from: date))"
    }

    private static let dayNumberFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

enum HomeTimelineGrouping {
    static func groups(
        calendarEvents: [CalendarEvent],
        savedSessions: [SessionIndex],
        savedSessionLimit: Int = 40,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [HomeTimelineDayGroup] {
        let entries = calendarEvents.map(HomeTimelineEntry.calendar)
            + savedSessions.prefix(savedSessionLimit).map(HomeTimelineEntry.savedSession)

        guard !entries.isEmpty else { return [] }

        let grouped = Dictionary(grouping: entries) { entry in
            calendar.startOfDay(for: entry.startDate)
        }
        let referenceDay = calendar.startOfDay(for: referenceDate)

        return grouped.keys
            .sorted { lhs, rhs in
                daySortKey(lhs, referenceDay: referenceDay) < daySortKey(rhs, referenceDay: referenceDay)
            }
            .map { day in
                HomeTimelineDayGroup(
                    date: day,
                    entries: grouped[day, default: []].sorted(by: entrySort)
                )
            }
    }

    private static func entrySort(_ lhs: HomeTimelineEntry, _ rhs: HomeTimelineEntry) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id < rhs.id
    }

    private static func daySortKey(_ day: Date, referenceDay: Date) -> DaySortKey {
        if day == referenceDay {
            return DaySortKey(bucket: 0, offset: 0)
        }
        if day > referenceDay {
            return DaySortKey(bucket: 1, offset: day.timeIntervalSince(referenceDay))
        }
        return DaySortKey(bucket: 2, offset: referenceDay.timeIntervalSince(day))
    }

    private struct DaySortKey: Comparable {
        let bucket: Int
        let offset: TimeInterval

        static func < (lhs: DaySortKey, rhs: DaySortKey) -> Bool {
            if lhs.bucket != rhs.bucket {
                return lhs.bucket < rhs.bucket
            }
            return lhs.offset < rhs.offset
        }
    }
}
