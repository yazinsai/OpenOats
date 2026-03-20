import XCTest
@testable import OpenOatsKit

final class MarkdownMeetingWriterTests: XCTestCase {

    // MARK: - Kebab Case Conversion

    func testKebabCaseBasic() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("Weekly Product Sync"), "weekly-product-sync")
    }

    func testKebabCaseWithSpecialCharacters() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("Q1 Launch: Planning!"), "q1-launch-planning")
    }

    func testKebabCaseCollapsesMultipleHyphens() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("hello---world"), "hello-world")
    }

    func testKebabCaseTrimsEdgeHyphens() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("--hello--"), "hello")
    }

    func testKebabCaseEmptyInputReturnsMeeting() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase(""), "meeting")
    }

    func testKebabCaseNonASCIIStripped() {
        // Non-ASCII characters are stripped; if only non-ASCII remains, returns "meeting"
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("spotkanie"), "spotkanie")
        // Pure non-ASCII (e.g., Chinese) should fallback
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("\u{4F1A}\u{8BAE}"), "meeting")
    }

    func testKebabCaseTruncatesLongStrings() {
        let longTitle = String(repeating: "a", count: 100)
        let result = MarkdownMeetingWriter.toKebabCase(longTitle)
        XCTAssertLessThanOrEqual(result.count, 60)
    }

    func testKebabCaseMixedASCIIAndNonASCII() {
        XCTAssertEqual(MarkdownMeetingWriter.toKebabCase("Meeting z klientem"), "meeting-z-klientem")
    }

    // MARK: - YAML Quoting

    func testYamlQuoteSimpleString() {
        XCTAssertEqual(MarkdownMeetingWriter.yamlQuote("Meeting"), "\"Meeting\"")
    }

    func testYamlQuoteStringWithColons() {
        XCTAssertEqual(
            MarkdownMeetingWriter.yamlQuote("Feature Flag Rollout: New Editor"),
            "\"Feature Flag Rollout: New Editor\""
        )
    }

    func testYamlQuoteStringWithDoubleQuotes() {
        XCTAssertEqual(
            MarkdownMeetingWriter.yamlQuote("The \"big\" meeting"),
            "\"The \\\"big\\\" meeting\""
        )
    }

    func testYamlQuoteStringWithBackslashes() {
        XCTAssertEqual(
            MarkdownMeetingWriter.yamlQuote("path\\to\\file"),
            "\"path\\\\to\\\\file\""
        )
    }

    func testYamlQuoteYesNoBooleanSafety() {
        // "yes" unquoted would be parsed as boolean true in YAML
        let result = MarkdownMeetingWriter.yamlQuote("yes")
        XCTAssertEqual(result, "\"yes\"")
    }

    // MARK: - Relative Timestamp Conversion

    func testRelativeTimestampZero() {
        let start = Date()
        XCTAssertEqual(
            MarkdownMeetingWriter.formatRelativeTimestamp(start, relativeTo: start),
            "00:00:00"
        )
    }

    func testRelativeTimestampMinutesAndSeconds() {
        let start = Date()
        let later = start.addingTimeInterval(65) // 1 min 5 sec
        XCTAssertEqual(
            MarkdownMeetingWriter.formatRelativeTimestamp(later, relativeTo: start),
            "00:01:05"
        )
    }

    func testRelativeTimestampOverOneHour() {
        let start = Date()
        let later = start.addingTimeInterval(3661) // 1 hour, 1 min, 1 sec
        XCTAssertEqual(
            MarkdownMeetingWriter.formatRelativeTimestamp(later, relativeTo: start),
            "01:01:01"
        )
    }

    func testRelativeTimestampNegativeClampedToZero() {
        let start = Date()
        let earlier = start.addingTimeInterval(-30) // 30 sec before start
        XCTAssertEqual(
            MarkdownMeetingWriter.formatRelativeTimestamp(earlier, relativeTo: start),
            "00:00:00"
        )
    }

    // MARK: - Transcript Line Formatting

    func testTranscriptLineFormat() {
        let start = Date()
        let records = [
            SessionRecord(speaker: .you, text: "Hello", timestamp: start),
            SessionRecord(speaker: .them, text: "Hi there", timestamp: start.addingTimeInterval(5)),
        ]

        let output = MarkdownMeetingWriter.formatTranscriptLines(records: records, startedAt: start)

        XCTAssertTrue(output.contains("[00:00:00] **You:** Hello"))
        XCTAssertTrue(output.contains("[00:00:05] **Them:** Hi there"))
    }

    func testTranscriptLinePrefersRefinedText() {
        let start = Date()
        let record = SessionRecord(
            speaker: .them,
            text: "um uh like hello",
            timestamp: start,
            refinedText: "Hello."
        )

        let output = MarkdownMeetingWriter.formatTranscriptLines(records: [record], startedAt: start)
        XCTAssertTrue(output.contains("**Them:** Hello."))
        XCTAssertFalse(output.contains("um uh like hello"))
    }

    func testTranscriptLineBlankLineSeparation() {
        let start = Date()
        let records = [
            SessionRecord(speaker: .you, text: "One", timestamp: start),
            SessionRecord(speaker: .them, text: "Two", timestamp: start.addingTimeInterval(3)),
        ]

        let output = MarkdownMeetingWriter.formatTranscriptLines(records: records, startedAt: start)
        let lines = output.components(separatedBy: "\n")

        // Should be: line1, blank, line2, blank (trailing)
        XCTAssertTrue(lines.count >= 4)
        XCTAssertTrue(lines[0].hasPrefix("[00:00:00]"))
        XCTAssertEqual(lines[1], "")
        XCTAssertTrue(lines[2].hasPrefix("[00:00:03]"))
    }

    // MARK: - Frontmatter Generation

    func testFrontmatterContainsRequiredFields() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "session_2026-03-20_14-00-06",
                startedAt: start,
                endedAt: start.addingTimeInterval(1920), // 32 minutes
                utteranceCount: 10,
                hasNotes: false,
                engine: "parakeetV2"
            )
        )

        let records = [
            SessionRecord(speaker: .you, text: "Hello", timestamp: start),
            SessionRecord(speaker: .them, text: "Hi", timestamp: start.addingTimeInterval(1920)),
        ]

        let frontmatter = MarkdownMeetingWriter.buildFrontmatter(
            metadata: metadata, records: records, title: "Meeting"
        )

        XCTAssertTrue(frontmatter.hasPrefix("---"))
        XCTAssertTrue(frontmatter.hasSuffix("---"))
        XCTAssertTrue(frontmatter.contains("schema: openoats/v1"))
        XCTAssertTrue(frontmatter.contains("title: \"Meeting\""))
        XCTAssertTrue(frontmatter.contains("duration: 32"))
        XCTAssertTrue(frontmatter.contains("participants:"))
        XCTAssertTrue(frontmatter.contains("  - You"))
        XCTAssertTrue(frontmatter.contains("  - Them"))
        XCTAssertTrue(frontmatter.contains("engine: parakeetV2"))
    }

    func testFrontmatterIncludesMeetingApp() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                utteranceCount: 1,
                hasNotes: false,
                meetingApp: "Zoom",
                engine: "parakeetV2"
            )
        )

        let records = [SessionRecord(speaker: .you, text: "Hi", timestamp: start)]
        let frontmatter = MarkdownMeetingWriter.buildFrontmatter(
            metadata: metadata, records: records, title: "Meeting"
        )

        XCTAssertTrue(frontmatter.contains("app: zoom"))
    }

    func testFrontmatterIncludesSessionExtension() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "session_2026-03-20_14-00-06",
                startedAt: start,
                utteranceCount: 1,
                hasNotes: false
            )
        )

        let records = [SessionRecord(speaker: .you, text: "Hi", timestamp: start)]
        let frontmatter = MarkdownMeetingWriter.buildFrontmatter(
            metadata: metadata, records: records, title: "Meeting"
        )

        XCTAssertTrue(frontmatter.contains("x_openoats_session: \"session_2026-03-20_14-00-06\""))
    }

    // MARK: - Duration Computation

    func testDurationFromEndedAt() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test",
                startedAt: start,
                endedAt: start.addingTimeInterval(1920), // 32 minutes
                utteranceCount: 2,
                hasNotes: false
            )
        )

        let records = [
            SessionRecord(speaker: .you, text: "a", timestamp: start),
            SessionRecord(speaker: .them, text: "b", timestamp: start.addingTimeInterval(60)),
        ]

        XCTAssertEqual(MarkdownMeetingWriter.computeDuration(records: records, metadata: metadata), 32)
    }

    func testDurationMinimumIsOne() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test",
                startedAt: start,
                endedAt: start.addingTimeInterval(10), // 10 seconds
                utteranceCount: 1,
                hasNotes: false
            )
        )

        let records = [SessionRecord(speaker: .you, text: "a", timestamp: start)]
        XCTAssertEqual(MarkdownMeetingWriter.computeDuration(records: records, metadata: metadata), 1)
    }

    // MARK: - App Name Normalization

    func testNormalizeAppNameZoom() {
        XCTAssertEqual(MarkdownMeetingWriter.normalizeAppName("Zoom"), "zoom")
    }

    func testNormalizeAppNameMicrosoftTeams() {
        XCTAssertEqual(MarkdownMeetingWriter.normalizeAppName("Microsoft Teams"), "teams")
    }

    func testNormalizeAppNameFaceTime() {
        XCTAssertEqual(MarkdownMeetingWriter.normalizeAppName("FaceTime"), "facetime")
    }

    func testNormalizeAppNameGoogleMeetPWA() {
        XCTAssertEqual(MarkdownMeetingWriter.normalizeAppName("Google Meet (PWA)"), "meet")
    }

    func testNormalizeAppNameUnknown() {
        XCTAssertEqual(MarkdownMeetingWriter.normalizeAppName("MyVideoApp"), "myvideoapp")
    }

    // MARK: - Full Markdown Output

    func testBuildMarkdownProducesCompleteFile() {
        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "session_2026-03-20_14-00-06",
                startedAt: start,
                endedAt: start.addingTimeInterval(120),
                utteranceCount: 2,
                hasNotes: false,
                meetingApp: "Zoom",
                engine: "parakeetV2"
            )
        )

        let records = [
            SessionRecord(speaker: .you, text: "Hello world", timestamp: start),
            SessionRecord(
                speaker: .them, text: "raw text",
                timestamp: start.addingTimeInterval(5),
                refinedText: "Refined text here."
            ),
        ]

        let markdown = MarkdownMeetingWriter.buildMarkdown(metadata: metadata, records: records)

        // Verify structure
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("schema: openoats/v1"))
        XCTAssertTrue(markdown.contains("# Meeting"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("[00:00:00] **You:** Hello world"))
        XCTAssertTrue(markdown.contains("[00:00:05] **Them:** Refined text here."))
        // Refined text should be used, not raw
        XCTAssertFalse(markdown.contains("raw text"))
    }

    // MARK: - File Writing

    func testWriteCreatesFileOnDisk() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test_session",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                utteranceCount: 1,
                hasNotes: false,
                engine: "parakeetV2"
            )
        )

        let records = [SessionRecord(speaker: .you, text: "Test", timestamp: start)]

        let fileURL = MarkdownMeetingWriter.write(
            metadata: metadata,
            records: records,
            outputDirectory: tmpDir
        )

        XCTAssertNotNil(fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL!.path))
        XCTAssertTrue(fileURL!.lastPathComponent.hasSuffix(".md"))

        // Verify content
        let content = try! String(contentsOf: fileURL!, encoding: .utf8)
        XCTAssertTrue(content.contains("schema: openoats/v1"))
    }

    func testWriteHandlesFilenameCollision() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let start = Date()
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test_session",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                utteranceCount: 1,
                hasNotes: false
            )
        )

        let records = [SessionRecord(speaker: .you, text: "Test", timestamp: start)]

        // Write first file
        let first = MarkdownMeetingWriter.write(
            metadata: metadata, records: records, outputDirectory: tmpDir
        )!

        // Write second file with same metadata (collision)
        let second = MarkdownMeetingWriter.write(
            metadata: metadata, records: records, outputDirectory: tmpDir
        )!

        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertTrue(second.lastPathComponent.contains("-2"))
    }

    func testWriteReturnsNilForEmptyRecords() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: "test", startedAt: Date(), utteranceCount: 0, hasNotes: false
            )
        )

        let result = MarkdownMeetingWriter.write(
            metadata: metadata, records: [], outputDirectory: tmpDir
        )

        XCTAssertNil(result)
    }

    // MARK: - LLM Section Extraction

    func testExtractLLMSectionsAllPresent() {
        let llmOutput = """
        ## Summary

        The team discussed the launch timeline and decided to move it up.

        ## Action Items

        - [ ] Update the timeline [owner:: You] [due:: 2026-03-25]
        - [ ] Run load testing [owner:: Them]

        ## Decisions

        - Launch date set to April 15
        - Collaborative editing deferred to v1.1
        """

        let sections = MarkdownMeetingWriter.extractLLMSections(from: llmOutput)

        XCTAssertTrue(sections.contains("## Summary"))
        XCTAssertTrue(sections.contains("## Action Items"))
        XCTAssertTrue(sections.contains("## Decisions"))
        XCTAssertTrue(sections.contains("[owner:: You]"))
    }

    func testExtractLLMSectionsOnlySummary() {
        let llmOutput = """
        ## Summary

        A brief discussion about the product roadmap.

        ## Key Points

        - Point one
        - Point two
        """

        let sections = MarkdownMeetingWriter.extractLLMSections(from: llmOutput)

        XCTAssertTrue(sections.contains("## Summary"))
        // Key Points is not a recognized section, should not be included
        XCTAssertFalse(sections.contains("## Key Points"))
    }

    // MARK: - Find Markdown File

    func testFindMarkdownFileBySessionID() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let start = Date()
        let sessionID = "session_2026-03-20_14-00-06"
        let metadata = MarkdownMeetingWriter.Metadata(
            from: SessionIndex(
                id: sessionID,
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                utteranceCount: 1,
                hasNotes: false
            )
        )

        let records = [SessionRecord(speaker: .you, text: "Test", timestamp: start)]
        MarkdownMeetingWriter.write(
            metadata: metadata, records: records, outputDirectory: tmpDir
        )

        let found = MarkdownMeetingWriter.findMarkdownFile(sessionID: sessionID, in: tmpDir)
        XCTAssertNotNil(found)
    }

    // MARK: - Filename Format

    func testFilenameFormatMatchesSpec() {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 20
        components.hour = 14
        components.minute = 0
        let date = calendar.date(from: components)!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = MarkdownMeetingWriter.resolveFilename(
            title: "Weekly Product Sync",
            startedAt: date,
            directory: tmpDir
        )

        XCTAssertEqual(url.lastPathComponent, "2026-03-20-1400-weekly-product-sync.md")
    }

    func testFilenameWithNilTitleUsesMeeting() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenOatsTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = MarkdownMeetingWriter.resolveFilename(
            title: nil,
            startedAt: Date(),
            directory: tmpDir
        )

        XCTAssertTrue(url.lastPathComponent.contains("-meeting.md"))
    }

    // MARK: - Speaker Label

    func testSpeakerLabelYou() {
        XCTAssertEqual(MarkdownMeetingWriter.speakerLabel(.you), "You")
    }

    func testSpeakerLabelThem() {
        XCTAssertEqual(MarkdownMeetingWriter.speakerLabel(.them), "Them")
    }

    // MARK: - ISO 8601 Formatting

    func testISO8601IncludesTimezone() {
        let result = MarkdownMeetingWriter.formatISO8601(Date())
        // Should contain a timezone offset like +01:00 or -05:00 or Z
        let hasTimezone = result.contains("+") || result.contains("Z") || result.hasSuffix("00")
        XCTAssertTrue(hasTimezone, "ISO 8601 date should include timezone: \(result)")
    }
}
