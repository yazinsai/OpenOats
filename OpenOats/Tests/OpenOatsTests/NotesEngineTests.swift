import XCTest
@testable import OpenOatsKit

final class NotesEngineTests: XCTestCase {
    private let genericTemplateID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func testBuildUserContentIncludesCalendarContext() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = [
            SessionRecord(speaker: .you, text: "Let's kick off.", timestamp: startedAt),
            SessionRecord(speaker: .them, text: "Sounds good.", timestamp: startedAt.addingTimeInterval(15)),
        ]
        let calendarEvent = CalendarEvent(
            id: "evt-42",
            title: "Board Prep",
            startDate: startedAt,
            endDate: startedAt.addingTimeInterval(1_800),
            organizer: "Alice",
            participants: [
                Participant(name: "Alice", email: "alice@example.com"),
                Participant(name: "Bob", email: "bob@example.com"),
                Participant(name: nil, email: "guest@example.com"),
            ],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/board-prep")
        )

        let content = NotesEngine.buildUserContent(
            transcript: transcript,
            calendarEvent: calendarEvent,
            scratchpad: "Mention the decision."
        )

        XCTAssertTrue(content.contains("Here is meeting context from the user's calendar:"))
        XCTAssertTrue(content.contains("- Title: Board Prep"))
        XCTAssertTrue(content.contains("- Organizer: Alice"))
        XCTAssertTrue(content.contains("  - Alice"))
        XCTAssertTrue(content.contains("  - Bob"))
        XCTAssertTrue(content.contains("  - guest@example.com"))
        XCTAssertTrue(content.contains("Mention the decision."))
        XCTAssertTrue(content.contains("You: Let's kick off."))
        XCTAssertFalse(content.contains("meet.example.com/board-prep"))
    }

    func testResolvedSystemPromptAddsCalendarGuidanceForGenericTemplate() {
        let template = MeetingTemplate(
            id: genericTemplateID,
            name: "Generic",
            icon: "doc.text",
            systemPrompt: "Base prompt",
            isBuiltIn: true
        )
        let calendarEvent = CalendarEvent(
            id: "evt-42",
            title: "Board Prep",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_001_800),
            organizer: "Alice",
            participants: [],
            isOnlineMeeting: true,
            meetingURL: nil
        )

        let resolved = NotesEngine.resolvedSystemPrompt(from: template, calendarEvent: calendarEvent)

        XCTAssertTrue(resolved.contains("## Meeting Context"))
        XCTAssertTrue(resolved.contains("invited participants"))
    }
}
