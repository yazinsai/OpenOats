import XCTest
@testable import OpenOatsKit

final class HomeTimelineGroupingTests: XCTestCase {
    func testGroupsCalendarEventsAndSavedSessionsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let reference = makeDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0, calendar: calendar)
        let todayEvent = makeEvent(
            id: "calendar-today",
            title: "Product Review",
            start: makeDate(year: 2026, month: 5, day: 6, hour: 15, minute: 0, calendar: calendar)
        )
        let yesterdaySession = makeSession(
            id: "session-yesterday",
            title: "Customer Call",
            startedAt: makeDate(year: 2026, month: 5, day: 5, hour: 10, minute: 0, calendar: calendar)
        )

        let groups = HomeTimelineGrouping.groups(
            calendarEvents: [todayEvent],
            savedSessions: [yesterdaySession],
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries, [.calendar(todayEvent)])
        XCTAssertEqual(groups[1].entries, [.savedSession(yesterdaySession)])
    }

    func testDayOrderingStartsWithTodayThenFutureThenRecentHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let reference = makeDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0, calendar: calendar)
        let yesterday = makeSession(
            id: "yesterday",
            title: "Yesterday",
            startedAt: makeDate(year: 2026, month: 5, day: 5, hour: 11, minute: 0, calendar: calendar)
        )
        let older = makeSession(
            id: "older",
            title: "Older",
            startedAt: makeDate(year: 2026, month: 5, day: 1, hour: 11, minute: 0, calendar: calendar)
        )
        let tomorrow = makeEvent(
            id: "tomorrow",
            title: "Tomorrow",
            start: makeDate(year: 2026, month: 5, day: 7, hour: 9, minute: 0, calendar: calendar)
        )
        let today = makeEvent(
            id: "today",
            title: "Today",
            start: makeDate(year: 2026, month: 5, day: 6, hour: 16, minute: 0, calendar: calendar)
        )

        let groups = HomeTimelineGrouping.groups(
            calendarEvents: [tomorrow, today],
            savedSessions: [older, yesterday],
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.entries.first?.id), [
            "calendar:today",
            "calendar:tomorrow",
            "session:yesterday",
            "session:older",
        ])
    }

    func testEntriesWithinDaySortByStartTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let reference = makeDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0, calendar: calendar)
        let late = makeEvent(
            id: "late",
            title: "Late",
            start: makeDate(year: 2026, month: 5, day: 6, hour: 16, minute: 0, calendar: calendar)
        )
        let early = makeSession(
            id: "early",
            title: "Early",
            startedAt: makeDate(year: 2026, month: 5, day: 6, hour: 9, minute: 0, calendar: calendar)
        )

        let groups = HomeTimelineGrouping.groups(
            calendarEvents: [late],
            savedSessions: [early],
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.map(\.id), ["session:early", "calendar:late"])
    }

    func testSavedSessionLimitIsApplied() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = [
            makeSession(id: "one", title: "One", startedAt: reference),
            makeSession(id: "two", title: "Two", startedAt: reference.addingTimeInterval(-60)),
            makeSession(id: "three", title: "Three", startedAt: reference.addingTimeInterval(-120)),
        ]

        let groups = HomeTimelineGrouping.groups(
            calendarEvents: [],
            savedSessions: sessions,
            savedSessionLimit: 2,
            referenceDate: reference
        )

        XCTAssertEqual(groups.flatMap(\.entries).map(\.id), ["session:two", "session:one"])
    }

    private func makeEvent(id: String, title: String, start: Date) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            externalIdentifier: nil,
            calendarID: nil,
            calendarTitle: nil,
            calendarColorHex: nil,
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
    }

    private func makeSession(id: String, title: String, startedAt: Date) -> SessionIndex {
        SessionIndex(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30 * 60),
            templateSnapshot: nil,
            title: title,
            utteranceCount: 3,
            hasNotes: false,
            language: nil,
            meetingApp: nil,
            engine: nil,
            tags: nil,
            source: nil
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
