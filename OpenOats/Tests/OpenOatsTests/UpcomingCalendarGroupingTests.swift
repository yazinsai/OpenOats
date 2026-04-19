import XCTest
@testable import OpenOatsKit

final class UpcomingCalendarGroupingTests: XCTestCase {
    func testSectionTitleUsesTodayAndTomorrowLabels() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let todayGroup = UpcomingCalendarGrouping.DayGroup(
            date: today,
            events: [makeEvent(id: "today", title: "Demo Day", start: today)]
        )
        let tomorrowGroup = UpcomingCalendarGrouping.DayGroup(
            date: tomorrow,
            events: [makeEvent(id: "tomorrow", title: "Planning", start: tomorrow)]
        )

        XCTAssertEqual(todayGroup.sectionTitle, "Today")
        XCTAssertEqual(tomorrowGroup.sectionTitle, "Tomorrow")
    }

    func testGroupsEventsByDayAndSortsWithinEachDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let morning = makeDate(year: 2026, month: 4, day: 20, hour: 9, minute: 45, calendar: calendar)
        let midday = makeDate(year: 2026, month: 4, day: 20, hour: 11, minute: 30, calendar: calendar)
        let nextDay = makeDate(year: 2026, month: 4, day: 21, hour: 14, minute: 30, calendar: calendar)

        let events = [
            makeEvent(id: "later", title: "Product Planning", start: midday),
            makeEvent(id: "next", title: "Platform Feedback", start: nextDay),
            makeEvent(id: "first", title: "Payment Ops", start: morning),
        ]

        let groups = UpcomingCalendarGrouping.groups(for: events, calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].events.map(\.id), ["first", "later"])
        XCTAssertEqual(groups[1].events.map(\.id), ["next"])
    }

    func testGroupDateUsesStartOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let eventDate = makeDate(year: 2026, month: 4, day: 22, hour: 9, minute: 45, calendar: calendar)
        let groups = UpcomingCalendarGrouping.groups(
            for: [makeEvent(id: "event", title: "Payment Ops", start: eventDate)],
            calendar: calendar
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].date, calendar.startOfDay(for: eventDate))
    }

    func testBestSessionMatchPrefersMostRecentNotesBearingSession() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = makeEvent(id: "evt", title: "Payment Ops", start: startedAt)
        let sessions = [
            SessionIndex(
                id: "older-notes",
                startedAt: startedAt.addingTimeInterval(-10_000),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Payment Ops",
                utteranceCount: 10,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
            SessionIndex(
                id: "newer-no-notes",
                startedAt: startedAt.addingTimeInterval(-1_000),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Payment Ops",
                utteranceCount: 8,
                hasNotes: false,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
            SessionIndex(
                id: "newest-notes",
                startedAt: startedAt.addingTimeInterval(-100),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Payment Ops",
                utteranceCount: 12,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
        ]

        let matched = UpcomingMeetingActionResolver.bestSessionMatch(for: event, sessionHistory: sessions)
        XCTAssertEqual(matched?.id, "newest-notes")
    }

    func testBestSessionMatchNormalizesTitlePunctuationAndWhitespace() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = makeEvent(id: "evt", title: "Payment Ops / Merchant stand up", start: startedAt)
        let sessions = [
            SessionIndex(
                id: "match",
                startedAt: startedAt.addingTimeInterval(-100),
                endedAt: nil,
                templateSnapshot: nil,
                title: "  Payment Ops Merchant   stand-up ",
                utteranceCount: 12,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
        ]

        let matched = UpcomingMeetingActionResolver.bestSessionMatch(for: event, sessionHistory: sessions)
        XCTAssertEqual(matched?.id, "match")
    }

    func testBestSessionMatchReturnsNilWithoutTitleMatch() {
        let event = makeEvent(id: "evt", title: "Design Review", start: Date())
        let sessions = [
            SessionIndex(
                id: "other",
                startedAt: Date().addingTimeInterval(-100),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Weekly Sync",
                utteranceCount: 5,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
        ]

        XCTAssertNil(UpcomingMeetingActionResolver.bestSessionMatch(for: event, sessionHistory: sessions))
    }

    private func makeEvent(id: String, title: String, start: Date) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
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
