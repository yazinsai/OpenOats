import XCTest
@testable import OpenOatsKit

final class SessionStoreTests: XCTestCase {

    private var store: SessionStore!

    override func setUp() async throws {
        store = SessionStore()
    }

    override func tearDown() async throws {
        // Clean up any session we created during the test
        if let sessionID = await store.currentSessionID {
            await store.endSession()
            await store.deleteSession(sessionID: sessionID)
        }
        store = nil
    }

    // MARK: - Session Lifecycle

    func testStartSessionSetsCurrentID() async {
        await store.startSession()
        let id = await store.currentSessionID
        XCTAssertNotNil(id)
        XCTAssertTrue(id!.hasPrefix("session_"))

        // Clean up
        await store.endSession()
        await store.deleteSession(sessionID: id!)
    }

    func testEndSessionClearsCurrentID() async {
        await store.startSession()
        let id = await store.currentSessionID
        XCTAssertNotNil(id)

        await store.endSession()
        let idAfter = await store.currentSessionID
        XCTAssertNil(idAfter)

        // Clean up
        if let id { await store.deleteSession(sessionID: id) }
    }

    func testAppendRecordWritesToFile() async {
        await store.startSession()
        let id = await store.currentSessionID!

        let record = SessionRecord(
            speaker: .them,
            text: "Hello from test",
            timestamp: Date()
        )
        await store.appendRecord(record)
        await store.endSession()

        let transcript = await store.loadTranscript(sessionID: id)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.text, "Hello from test")
        XCTAssertEqual(transcript.first?.speaker, .them)

        await store.deleteSession(sessionID: id)
    }

    func testAppendMultipleRecords() async {
        await store.startSession()
        let id = await store.currentSessionID!

        for i in 1...5 {
            let record = SessionRecord(
                speaker: i.isMultiple(of: 2) ? .you : .them,
                text: "Utterance \(i)",
                timestamp: Date()
            )
            await store.appendRecord(record)
        }
        await store.endSession()

        let transcript = await store.loadTranscript(sessionID: id)
        XCTAssertEqual(transcript.count, 5)
        XCTAssertEqual(transcript[0].text, "Utterance 1")
        XCTAssertEqual(transcript[4].text, "Utterance 5")

        await store.deleteSession(sessionID: id)
    }

    // MARK: - Sidecar

    func testWriteAndReadSidecar() async {
        await store.startSession()
        let id = await store.currentSessionID!
        await store.endSession()

        let template = TemplateSnapshot(
            id: UUID(),
            name: "Test Template",
            icon: "star",
            systemPrompt: "Be helpful"
        )
        let index = SessionIndex(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            utteranceCount: 3,
            hasNotes: true
        )
        let notes = EnhancedNotes(
            template: template,
            generatedAt: Date(timeIntervalSince1970: 1_000_100),
            markdown: "# Test Notes\n\nSome content here."
        )
        let sidecar = SessionSidecar(index: index, notes: notes)

        await store.writeSidecar(sidecar)

        let loadedNotes = await store.loadNotes(sessionID: id)
        XCTAssertNotNil(loadedNotes)
        XCTAssertEqual(loadedNotes?.markdown, "# Test Notes\n\nSome content here.")
        XCTAssertEqual(loadedNotes?.template.name, "Test Template")

        await store.deleteSession(sessionID: id)
    }

    // MARK: - Session Index

    func testLoadSessionIndexIncludesCreatedSession() async {
        await store.startSession()
        let id = await store.currentSessionID!

        let record = SessionRecord(speaker: .them, text: "Index test", timestamp: Date())
        await store.appendRecord(record)
        await store.endSession()

        let indices = await store.loadSessionIndex()
        let found = indices.first(where: { $0.id == id })
        XCTAssertNotNil(found, "Created session should appear in index")

        await store.deleteSession(sessionID: id)
    }

    func testLoadSessionIndexSortedByDate() async {
        let indices = await store.loadSessionIndex()
        // Verify descending order (most recent first)
        for i in 0..<max(0, indices.count - 1) {
            XCTAssertGreaterThanOrEqual(indices[i].startedAt, indices[i + 1].startedAt)
        }
    }

    // MARK: - Delete

    func testDeleteSessionRemovesFiles() async {
        await store.startSession()
        let id = await store.currentSessionID!
        await store.appendRecord(SessionRecord(speaker: .them, text: "Delete me", timestamp: Date()))
        await store.endSession()

        // Verify it exists
        let before = await store.loadTranscript(sessionID: id)
        XCTAssertFalse(before.isEmpty)

        // Delete
        await store.deleteSession(sessionID: id)

        // Verify it's gone
        let after = await store.loadTranscript(sessionID: id)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Load Transcript for Missing Session

    func testLoadTranscriptForNonexistentSession() async {
        let transcript = await store.loadTranscript(sessionID: "nonexistent_session_xyz")
        XCTAssertTrue(transcript.isEmpty)
    }

    func testLoadNotesForNonexistentSession() async {
        let notes = await store.loadNotes(sessionID: "nonexistent_session_xyz")
        XCTAssertNil(notes)
    }

    // MARK: - SessionRecord Encoding/Decoding

    func testSessionRecordRoundTrip() throws {
        let record = SessionRecord(
            speaker: .you,
            text: "Hello there",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            suggestions: ["Try asking about X"],
            kbHits: ["doc.md"],
            refinedText: "Hello there."
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)

        XCTAssertEqual(decoded.speaker, .you)
        XCTAssertEqual(decoded.text, "Hello there")
        XCTAssertEqual(decoded.suggestions, ["Try asking about X"])
        XCTAssertEqual(decoded.kbHits, ["doc.md"])
        XCTAssertEqual(decoded.refinedText, "Hello there.")
    }

    func testSessionRecordMinimalFields() throws {
        let record = SessionRecord(
            speaker: .them,
            text: "Minimal",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)

        XCTAssertEqual(decoded.speaker, .them)
        XCTAssertEqual(decoded.text, "Minimal")
        XCTAssertNil(decoded.suggestions)
        XCTAssertNil(decoded.kbHits)
        XCTAssertNil(decoded.refinedText)
    }
}
