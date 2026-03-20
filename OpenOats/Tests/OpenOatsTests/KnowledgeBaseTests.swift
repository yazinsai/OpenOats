import XCTest
@testable import OpenOatsKit

final class KnowledgeBaseTests: XCTestCase {

    // MARK: - TextSimilarity.normalizedWords

    func testNormalizedWordsLowercases() {
        let words = TextSimilarity.normalizedWords(in: "Hello WORLD")
        XCTAssertEqual(words, ["hello", "world"])
    }

    func testNormalizedWordsRemovesPunctuation() {
        let words = TextSimilarity.normalizedWords(in: "Hello, world! How's it going?")
        XCTAssertEqual(words, ["hello", "world", "how", "s", "it", "going"])
    }

    func testNormalizedWordsHandlesEmpty() {
        let words = TextSimilarity.normalizedWords(in: "")
        XCTAssertTrue(words.isEmpty)
    }

    func testNormalizedWordsHandlesWhitespaceOnly() {
        let words = TextSimilarity.normalizedWords(in: "   \n\t  ")
        XCTAssertTrue(words.isEmpty)
    }

    func testNormalizedWordsHandlesNumbers() {
        let words = TextSimilarity.normalizedWords(in: "Test 123 value")
        XCTAssertEqual(words, ["test", "123", "value"])
    }

    // MARK: - TextSimilarity.normalizedText

    func testNormalizedTextJoinsWithSpaces() {
        let text = TextSimilarity.normalizedText("Hello, WORLD!")
        XCTAssertEqual(text, "hello world")
    }

    func testNormalizedTextEmpty() {
        let text = TextSimilarity.normalizedText("")
        XCTAssertEqual(text, "")
    }

    // MARK: - TextSimilarity.jaccard

    func testJaccardIdenticalStrings() {
        let score = TextSimilarity.jaccard("hello world", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardCompletelyDifferent() {
        let score = TextSimilarity.jaccard("hello world", "foo bar")
        XCTAssertEqual(score, 0.0, accuracy: 0.001)
    }

    func testJaccardPartialOverlap() {
        let score = TextSimilarity.jaccard("hello world foo", "hello world bar")
        // Sets: {hello, world, foo} and {hello, world, bar}
        // Intersection = 2, Union = 4
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    func testJaccardBothEmpty() {
        let score = TextSimilarity.jaccard("", "")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardCaseInsensitive() {
        let score = TextSimilarity.jaccard("HELLO WORLD", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardIgnoresPunctuation() {
        let score = TextSimilarity.jaccard("Hello, world!", "hello world")
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testJaccardSubsetScore() {
        // "hello" is a subset of "hello world"
        let score = TextSimilarity.jaccard("hello", "hello world")
        // Intersection = 1, Union = 2
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    // MARK: - KBChunk Model

    func testKBChunkCodable() throws {
        let chunk = KBChunk(
            text: "Some knowledge base text",
            sourceFile: "notes.md",
            headerContext: "Section > Subsection",
            embedding: [0.1, 0.2, 0.3]
        )

        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(KBChunk.self, from: data)

        XCTAssertEqual(decoded.text, "Some knowledge base text")
        XCTAssertEqual(decoded.sourceFile, "notes.md")
        XCTAssertEqual(decoded.headerContext, "Section > Subsection")
        XCTAssertEqual(decoded.embedding, [0.1, 0.2, 0.3])
    }

    // MARK: - KBResult Model

    func testKBResultFields() {
        let result = KBResult(
            text: "Relevant text",
            sourceFile: "doc.md",
            headerContext: "API > Endpoints",
            score: 0.95
        )
        XCTAssertEqual(result.text, "Relevant text")
        XCTAssertEqual(result.sourceFile, "doc.md")
        XCTAssertEqual(result.headerContext, "API > Endpoints")
        XCTAssertEqual(result.score, 0.95, accuracy: 0.001)
    }

    func testKBResultIdentifiable() {
        let a = KBResult(text: "A", sourceFile: "a.md", score: 0.5)
        let b = KBResult(text: "B", sourceFile: "b.md", score: 0.6)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testKBResultCodable() throws {
        let result = KBResult(
            text: "Sample",
            sourceFile: "file.md",
            headerContext: "Header",
            score: 0.8
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(KBResult.self, from: data)
        XCTAssertEqual(decoded.text, "Sample")
        XCTAssertEqual(decoded.sourceFile, "file.md")
        XCTAssertEqual(decoded.score, 0.8, accuracy: 0.001)
    }
}
