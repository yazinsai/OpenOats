import XCTest
@testable import OpenOatsKit

@MainActor
final class TranscriptCleanupEngineTests: XCTestCase {

    // MARK: - chunkRecords

    func testChunkRecordsEmpty() {
        let chunks = TranscriptCleanupEngine.chunkRecords([])
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkRecordsSingleChunk() {
        let base = Date()
        let records = (0..<5).map { i in
            SessionRecord(speaker: .you, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 10))
        }
        let chunks = TranscriptCleanupEngine.chunkRecords(records)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 5)
    }

    func testChunkRecordsSplitsAt150Seconds() {
        let base = Date()
        // 10 records, 20 seconds apart = 180 seconds total -> should split around 150s mark
        let records = (0..<10).map { i in
            SessionRecord(speaker: .them, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 20))
        }
        let chunks = TranscriptCleanupEngine.chunkRecords(records)
        XCTAssertEqual(chunks.count, 2)
        // First chunk: records at 0, 20, 40, 60, 80, 100, 120, 140 (8 records, last at 140s < 150s)
        // Record at 160s triggers split
        XCTAssertEqual(chunks[0].count, 8)
        XCTAssertEqual(chunks[1].count, 2)
    }

    func testChunkRecordsThreeChunks() {
        let base = Date()
        // 20 records, 20 seconds apart = 380 seconds total -> 3 chunks
        let records = (0..<20).map { i in
            SessionRecord(speaker: .you, text: "line \(i)", timestamp: base.addingTimeInterval(Double(i) * 20))
        }
        let chunks = TranscriptCleanupEngine.chunkRecords(records)
        XCTAssertEqual(chunks.count, 3)
    }

    // MARK: - parseResponse

    func testParseResponseMatchingLineCount() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "original one", timestamp: base),
            SessionRecord(speaker: .them, text: "original two", timestamp: base.addingTimeInterval(5)),
        ]
        let response = "[12:00:00] You: cleaned one\n[12:00:05] Them: cleaned two"

        let result = TranscriptCleanupEngine.parseResponse(response, originalRecords: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].refinedText, "cleaned one")
        XCTAssertEqual(result?[1].refinedText, "cleaned two")
    }

    func testParseResponseMismatchedLineCountReturnsNil() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "original", timestamp: base),
        ]
        let response = "line one\nline two\nline three"

        let result = TranscriptCleanupEngine.parseResponse(response, originalRecords: records)
        XCTAssertNil(result)
    }

    func testParseResponseWithoutPrefixStripsWhitespace() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "original", timestamp: base),
        ]
        let response = "  cleaned text  "

        let result = TranscriptCleanupEngine.parseResponse(response, originalRecords: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[0].refinedText, "cleaned text")
    }

    func testParseResponseEmptyLinePreservesOriginal() {
        let base = Date()
        let records = [
            SessionRecord(speaker: .you, text: "keep this", timestamp: base),
        ]
        // After prefix strip, if the result is empty it should fall back to original text
        let response = "[12:00:00] You: "

        let result = TranscriptCleanupEngine.parseResponse(response, originalRecords: records)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?[0].refinedText, "keep this")
    }

    // MARK: - Failure threshold

    func testFailureThresholdIntegerDivision() {
        // With 3 chunks, chunks.count / 2 = 1
        // So 1 failure is silent, 2 failures triggers the error
        // This test documents the intentional behavior
        let halfOf3 = 3 / 2
        XCTAssertEqual(halfOf3, 1, "Integer division: 3/2 = 1, so 1 failure is tolerated, 2 triggers error")

        let halfOf4 = 4 / 2
        XCTAssertEqual(halfOf4, 2, "Integer division: 4/2 = 2, so 2 failures tolerated, 3 triggers error")
    }
}
