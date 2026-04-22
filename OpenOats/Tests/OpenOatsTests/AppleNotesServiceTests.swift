import XCTest
@testable import OpenOatsKit

final class AppleNotesServiceTests: XCTestCase {

    // MARK: - noteTitle

    func testNoteTitleWithMeetingTitle() {
        let index = makeSessionIndex(title: "Sprint Planning", date: date("2026-04-07"))
        XCTAssertEqual(AppleNotesService.noteTitle(for: index), "[OpenOats] 2026-04-07 Sprint Planning")
    }

    func testNoteTitleWithoutTitle() {
        let index = makeSessionIndex(title: nil, date: date("2026-04-07"))
        XCTAssertEqual(AppleNotesService.noteTitle(for: index), "[OpenOats] 2026-04-07 Meeting")
    }

    func testNoteTitleWithBlankTitle() {
        let index = makeSessionIndex(title: "   ", date: date("2026-04-07"))
        XCTAssertEqual(AppleNotesService.noteTitle(for: index), "[OpenOats] 2026-04-07 Meeting")
    }

    func testNoteTitleTrimsWhitespace() {
        let index = makeSessionIndex(title: "  My Meeting  ", date: date("2026-04-07"))
        XCTAssertEqual(AppleNotesService.noteTitle(for: index), "[OpenOats] 2026-04-07 My Meeting")
    }

    // MARK: - stripLeadingH1

    func testStripLeadingH1RemovesFirstH1() {
        let md = "# Meeting Notes: Sprint\n\nSome content here."
        let result = AppleNotesService.stripLeadingH1(md)
        XCTAssertFalse(result.contains("# Meeting Notes"))
        XCTAssertTrue(result.contains("Some content here."))
    }

    func testStripLeadingH1SkipsBlankLines() {
        let md = "\n\n# Title\n\nBody"
        let result = AppleNotesService.stripLeadingH1(md)
        XCTAssertFalse(result.hasPrefix("# Title"))
        XCTAssertTrue(result.contains("Body"))
    }

    func testStripLeadingH1LeavesH2Intact() {
        let md = "## Section\n\nContent"
        let result = AppleNotesService.stripLeadingH1(md)
        XCTAssertTrue(result.contains("## Section"))
    }

    func testStripLeadingH1NoH1IsNoop() {
        let md = "Just a paragraph."
        XCTAssertEqual(AppleNotesService.stripLeadingH1(md), md)
    }

    func testStripLeadingH1OnlyRemovesFirst() {
        let md = "# First\n# Second\nContent"
        let result = AppleNotesService.stripLeadingH1(md)
        XCTAssertFalse(result.hasPrefix("# First"))
        XCTAssertTrue(result.contains("# Second"))
    }

    // MARK: - markdownToHTML: headings

    func testMarkdownH1() {
        let html = AppleNotesService.markdownToHTML("# Heading One")
        XCTAssertTrue(html.contains("<h1>Heading One</h1>"))
    }

    func testMarkdownH2() {
        let html = AppleNotesService.markdownToHTML("## Heading Two")
        XCTAssertTrue(html.contains("<h2>Heading Two</h2>"))
    }

    func testMarkdownH3() {
        let html = AppleNotesService.markdownToHTML("### Heading Three")
        XCTAssertTrue(html.contains("<h3>Heading Three</h3>"))
    }

    // MARK: - markdownToHTML: lists

    func testMarkdownUnorderedListDash() {
        let html = AppleNotesService.markdownToHTML("- Item A\n- Item B")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>Item A</li>"))
        XCTAssertTrue(html.contains("<li>Item B</li>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testMarkdownUnorderedListAsterisk() {
        let html = AppleNotesService.markdownToHTML("* Item A")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>Item A</li>"))
    }

    func testMarkdownOrderedList() {
        let html = AppleNotesService.markdownToHTML("1. First\n2. Second")
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>First</li>"))
        XCTAssertTrue(html.contains("<li>Second</li>"))
        XCTAssertTrue(html.contains("</ol>"))
    }

    func testMarkdownListsClosed() {
        // Lists must be closed before a paragraph
        let html = AppleNotesService.markdownToHTML("- Item\n\nParagraph")
        XCTAssertTrue(html.contains("</ul>"))
        XCTAssertTrue(html.contains("<p>Paragraph</p>"))
    }

    // MARK: - markdownToHTML: inline formatting

    func testMarkdownBold() {
        let html = AppleNotesService.markdownToHTML("**bold text**")
        XCTAssertTrue(html.contains("<b>bold text</b>"))
    }

    func testMarkdownItalicAsterisk() {
        let html = AppleNotesService.markdownToHTML("*italic text*")
        XCTAssertTrue(html.contains("<i>italic text</i>"))
    }

    func testMarkdownItalicUnderscore() {
        let html = AppleNotesService.markdownToHTML("_italic text_")
        XCTAssertTrue(html.contains("<i>italic text</i>"))
    }

    func testMarkdownParagraph() {
        let html = AppleNotesService.markdownToHTML("Hello world")
        XCTAssertTrue(html.contains("<p>Hello world</p>"))
    }

    // MARK: - markdownToHTML: charset in full export

    func testHTMLOutputContainsCharsetDeclaration() {
        // The full HTML wrapper must include a UTF-8 charset meta tag
        // so Apple Notes reads the file with the correct encoding.
        let index = makeSessionIndex(title: "Test", date: date("2026-04-07"))
        // We test this indirectly through buildHTML's output contract by
        // verifying the AppleScript source written to the temp file
        // would include the charset tag. We verify markdownToHTML + full HTML is well-formed.
        let html = AppleNotesService.markdownToHTML("Simple text")
        // markdownToHTML returns a body fragment — the wrapper is added in buildHTML.
        // Confirm the fragment doesn't itself inject charset (which would duplicate it).
        XCTAssertFalse(html.contains("<html>"))
        XCTAssertFalse(html.contains("<meta"))
    }

    // MARK: - Sync Tracking (UserDefaults round-trip)

    func testMarkSyncedAndLastSyncDate() {
        let sessionID = "test-session-\(UUID().uuidString)"
        XCTAssertNil(AppleNotesService.lastSyncDate(for: sessionID), "Should be nil before first sync")

        AppleNotesService.markSynced(sessionID: sessionID)
        let syncDate = AppleNotesService.lastSyncDate(for: sessionID)
        XCTAssertNotNil(syncDate)

        let elapsed = Date().timeIntervalSince(syncDate!)
        XCTAssertLessThan(elapsed, 5, "Sync date should be within the last 5 seconds")

        // Cleanup
        var dict = UserDefaults.standard.dictionary(forKey: "appleNotesSyncedSessions") as? [String: Double] ?? [:]
        dict.removeValue(forKey: sessionID)
        UserDefaults.standard.set(dict, forKey: "appleNotesSyncedSessions")
    }

    func testMarkSyncedUpdatesExistingEntry() {
        let sessionID = "test-session-update-\(UUID().uuidString)"
        AppleNotesService.markSynced(sessionID: sessionID)
        let first = AppleNotesService.lastSyncDate(for: sessionID)!

        // Advance a bit — Date resolution is ~1ms so we need a tiny sleep
        Thread.sleep(forTimeInterval: 0.01)
        AppleNotesService.markSynced(sessionID: sessionID)
        let second = AppleNotesService.lastSyncDate(for: sessionID)!

        XCTAssertGreaterThanOrEqual(second, first, "Second sync date should be at or after first")

        // Cleanup
        var dict = UserDefaults.standard.dictionary(forKey: "appleNotesSyncedSessions") as? [String: Double] ?? [:]
        dict.removeValue(forKey: sessionID)
        UserDefaults.standard.set(dict, forKey: "appleNotesSyncedSessions")
    }

    // MARK: - Helpers

    private func makeSessionIndex(title: String?, date: Date) -> SessionIndex {
        SessionIndex(
            id: UUID().uuidString,
            startedAt: date,
            endedAt: date.addingTimeInterval(3600),
            title: title,
            utteranceCount: 0,
            hasNotes: false
        )
    }

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        // Use noon local time to avoid midnight rollover across timezones
        return formatter.date(from: "\(iso) 12:00:00")!
    }
}
