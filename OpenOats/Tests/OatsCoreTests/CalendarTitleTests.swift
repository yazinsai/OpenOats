import Foundation
import OatsCore
import Testing

/// Which calendar event names a recording.
@Suite struct CalendarTitleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ title: String, _ from: Int, _ to: Int, withOthers: Bool = true) -> CalendarEvent {
        CalendarEvent(title: title, start: t0 + Double(from * 60), end: t0 + Double(to * 60), withOthers: withOthers)
    }

    func title(_ from: Int, _ to: Int, _ events: [CalendarEvent]) -> String? {
        CalendarEvent.title(for: DateInterval(start: t0 + Double(from * 60), end: t0 + Double(to * 60)), in: events)
    }

    @Test func theMeetingTheRecordingIsIn() {
        #expect(title(2, 28, [event("Weekly sync", 0, 30)]) == "Weekly sync")
    }

    @Test func startedLateOrRanOver() {
        #expect(title(10, 45, [event("Weekly sync", 0, 30)]) == "Weekly sync")
    }

    @Test func noEventMeansNoTitle() {
        #expect(title(0, 30, []) == nil)
    }

    @Test func personalBlocksDontName() {
        #expect(title(0, 30, [event("Focus", 0, 120, withOthers: false)]) == nil)
        #expect(title(0, 30, [event("Focus", 0, 120, withOthers: false), event("1:1 with Sam", 0, 30)]) == "1:1 with Sam")
    }

    @Test func joinedEarlyBelongsToTheNextMeeting() {
        // 1.x #706: a recording started in the tail of the previous meeting was named after it.
        #expect(title(58, 90, [event("Standup", 30, 60), event("Design review", 60, 90)]) == "Design review")
    }

    @Test func aCallRightAfterAMeetingIsNotNamedAfterIt() {
        #expect(title(25, 50, [event("Standup", 0, 30)]) == nil)
        #expect(title(30, 50, [event("Standup", 0, 30)]) == nil)
    }

    @Test func theShorterMeetingInsideABlockWins() {
        #expect(title(0, 30, [event("Offsite", 0, 180), event("Pricing", 0, 30)]) == "Pricing")
    }

    @Test func aShortRecordingInsideALongMeeting() {
        #expect(title(40, 42, [event("All-hands", 0, 120)]) == "All-hands")
    }

    @Test func untitledEventsAreSkipped() {
        #expect(title(0, 30, [event("  ", 0, 30)]) == nil)
    }
}
