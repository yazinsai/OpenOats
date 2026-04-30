import XCTest
@testable import OpenOatsKit

final class NoteAssetMarkdownParserTests: XCTestCase {
    func testParseBodyKeepsPlainTextParagraphs() {
        let blocks = NoteAssetMarkdownParser.parseBody("First paragraph\nwith two lines.\n\nSecond paragraph")

        XCTAssertEqual(
            blocks,
            [
                .text("First paragraph\nwith two lines."),
                .text("Second paragraph"),
            ]
        )
    }

    func testParseBodyPromotesStandaloneImageMarkdown() {
        let blocks = NoteAssetMarkdownParser.parseBody("Before\n\n![Whiteboard](images/diagram.png)\n\nAfter")

        XCTAssertEqual(
            blocks,
            [
                .text("Before"),
                .image(altText: "Whiteboard", relativePath: "images/diagram.png"),
                .text("After"),
            ]
        )
    }

    func testParseBodyPromotesStandaloneLocalAttachmentLinks() {
        let blocks = NoteAssetMarkdownParser.parseBody("[Spec Deck](attachments/spec-deck.pdf)")

        XCTAssertEqual(
            blocks,
            [
                .fileLink(label: "Spec Deck", relativePath: "attachments/spec-deck.pdf"),
            ]
        )
    }

    func testParseBodyPromotesImageAttachmentsAsImages() {
        let blocks = NoteAssetMarkdownParser.parseBody("[Mockup](attachments/mockup.png)")

        XCTAssertEqual(
            blocks,
            [
                .image(altText: "Mockup", relativePath: "attachments/mockup.png"),
            ]
        )
    }

    func testParseBodyLeavesInlineLinksInsideTextUntouched() {
        let blocks = NoteAssetMarkdownParser.parseBody("See [Spec Deck](attachments/spec-deck.pdf) before Friday.")

        XCTAssertEqual(
            blocks,
            [
                .text("See [Spec Deck](attachments/spec-deck.pdf) before Friday."),
            ]
        )
    }

    func testParseBodyRejectsTraversalPaths() {
        let blocks = NoteAssetMarkdownParser.parseBody("[Bad](attachments/../secret.txt)")

        XCTAssertEqual(
            blocks,
            [
                .text("[Bad](attachments/../secret.txt)"),
            ]
        )
    }
}
