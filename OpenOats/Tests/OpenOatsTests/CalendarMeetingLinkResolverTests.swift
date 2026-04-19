import XCTest
@testable import OpenOatsKit

final class CalendarMeetingLinkResolverTests: XCTestCase {
    func testMeetingURLPrefersRawEventURL() {
        let rawURL = URL(string: "https://meet.google.com/raw-room")!

        let resolved = CalendarMeetingLinkResolver.meetingURL(
            rawURL: rawURL,
            notes: "Join on Zoom: https://zoom.us/j/123456",
            location: nil
        )

        XCTAssertEqual(resolved, rawURL)
    }

    func testMeetingURLExtractsConferenceLinkFromNotes() {
        let resolved = CalendarMeetingLinkResolver.meetingURL(
            rawURL: nil,
            notes: "Agenda doc https://docs.example.com/agenda\nJoin here https://teams.microsoft.com/l/meetup-join/abc",
            location: nil
        )

        XCTAssertEqual(resolved?.host, "teams.microsoft.com")
    }

    func testMeetingURLExtractsConferenceLinkFromLocation() {
        let resolved = CalendarMeetingLinkResolver.meetingURL(
            rawURL: nil,
            notes: nil,
            location: "https://zoom.us/j/123456789?pwd=xyz"
        )

        XCTAssertEqual(resolved?.host, "zoom.us")
    }

    func testMeetingURLReturnsNilForNonMeetingLinksOnly() {
        let resolved = CalendarMeetingLinkResolver.meetingURL(
            rawURL: nil,
            notes: "Agenda: https://docs.example.com/agenda",
            location: "Office 3B"
        )

        XCTAssertNil(resolved)
    }

    func testIsOnlineMeetingReturnsTrueForMeetingHintsWithoutURL() {
        XCTAssertTrue(
            CalendarMeetingLinkResolver.isOnlineMeeting(
                rawURL: nil,
                notes: "Teams call",
                location: nil
            )
        )
    }
}
