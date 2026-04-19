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

    func testMeetingHistoryResolverMatchesNormalizedTitlesNewestFirst() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = makeEvent(id: "evt", title: "Payment Ops / Merchant stand up", start: startedAt)
        let sessions = [
            SessionIndex(
                id: "older",
                startedAt: startedAt.addingTimeInterval(-1_000),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Payment Ops Merchant stand-up",
                utteranceCount: 8,
                hasNotes: false,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
            SessionIndex(
                id: "newer",
                startedAt: startedAt.addingTimeInterval(-100),
                endedAt: nil,
                templateSnapshot: nil,
                title: "  Payment Ops Merchant   stand up  ",
                utteranceCount: 12,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil
            ),
        ]

        let matched = MeetingHistoryResolver.matchingSessions(for: event, sessionHistory: sessions)
        XCTAssertEqual(matched.map(\.id), ["newer", "older"])
    }

    func testMeetingHistoryResolverReturnsEmptyWithoutTitleMatch() {
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

        XCTAssertTrue(MeetingHistoryResolver.matchingSessions(for: event, sessionHistory: sessions).isEmpty)
    }

    func testSelectionPrefersCalendarCoverageBeforeFillingRemainingSlots() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            makeEvent(id: "a1", title: "Alpha 1", start: base.addingTimeInterval(60), calendarID: "A", calendarTitle: "Work"),
            makeEvent(id: "a2", title: "Alpha 2", start: base.addingTimeInterval(120), calendarID: "A", calendarTitle: "Work"),
            makeEvent(id: "a3", title: "Alpha 3", start: base.addingTimeInterval(180), calendarID: "A", calendarTitle: "Work"),
            makeEvent(id: "b1", title: "Beta 1", start: base.addingTimeInterval(240), calendarID: "B", calendarTitle: "Personal"),
            makeEvent(id: "c1", title: "Gamma 1", start: base.addingTimeInterval(300), calendarID: "C", calendarTitle: "Side"),
        ]

        let selected = UpcomingEventSelection.select(from: events, limit: 4)

        XCTAssertEqual(selected.map(\.id), ["a1", "a2", "b1", "c1"])
    }

    func testDistinctCalendarCountUsesCalendarIdentity() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            makeEvent(id: "a1", title: "Alpha 1", start: base, calendarID: "A", calendarTitle: "Work"),
            makeEvent(id: "a2", title: "Alpha 2", start: base.addingTimeInterval(60), calendarID: "A", calendarTitle: "Work"),
            makeEvent(id: "b1", title: "Beta 1", start: base.addingTimeInterval(120), calendarID: "B", calendarTitle: "Personal"),
        ]

        XCTAssertEqual(UpcomingEventSelection.distinctCalendarCount(in: events), 2)
    }

    private func makeEvent(
        id: String,
        title: String,
        start: Date,
        calendarID: String? = nil,
        calendarTitle: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            calendarID: calendarID,
            calendarTitle: calendarTitle,
            calendarColorHex: nil,
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
