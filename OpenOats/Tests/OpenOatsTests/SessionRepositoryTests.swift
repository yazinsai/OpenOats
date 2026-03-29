import XCTest
@testable import OpenOatsKit

final class SessionRepositoryTests: XCTestCase {

    private var repo: SessionRepository!
    private var rootDir: URL!

    override func setUp() async throws {
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsRepoTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        repo = SessionRepository(rootDirectory: rootDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        repo = nil
    }

    // MARK: - startSession creates canonical directory layout

    func testStartSessionCreatesDirectoryLayout() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("session.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("transcript.live.jsonl").path
        ))

        await repo.endSession()
        await repo.deleteSession(sessionID: sessionID)
    }

    func testStartSessionSetsCurrentID() async {
        let handle = await repo.startSession()
        let id = await repo.getCurrentSessionID()
        XCTAssertNotNil(id)
        XCTAssertEqual(id, handle.sessionID)
        XCTAssertTrue(id!.hasPrefix("session_"))

        await repo.endSession()
        await repo.deleteSession(sessionID: handle.sessionID)
    }

    // MARK: - appendLiveUtterance writes to JSONL

    func testAppendLiveUtteranceWritesToJSONL() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        let utterance = Utterance(text: "Hello from test", speaker: .them, timestamp: Date())
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        await repo.endSession()

        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.text, "Hello from test")
        XCTAssertEqual(transcript.first?.speaker, .them)

        await repo.deleteSession(sessionID: sessionID)
    }

    func testAppendMultipleUtterances() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        for i in 1...5 {
            let utterance = Utterance(
                text: "Utterance \(i)",
                speaker: i.isMultiple(of: 2) ? .you : .them,
                timestamp: Date()
            )
            await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        }
        await repo.endSession()

        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 5)
        XCTAssertEqual(transcript[0].text, "Utterance 1")
        XCTAssertEqual(transcript[4].text, "Utterance 5")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - finalizeSession writes session.json

    func testFinalizeSessionWritesMetadata() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID
        let startDate = Date()

        let utterance = Utterance(text: "Test", speaker: .you, timestamp: startDate)
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)

        await repo.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: 1,
                title: "Test Meeting",
                language: "fr-FR",
                meetingApp: "Zoom",
                engine: "parakeetV2",
                templateSnapshot: nil,
                utterances: [utterance]
            )
        )

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Test Meeting")
        XCTAssertEqual(found?.language, "fr-FR")
        XCTAssertEqual(found?.meetingApp, "Zoom")
        XCTAssertEqual(found?.engine, "parakeetV2")
        XCTAssertEqual(found?.utteranceCount, 1)
        XCTAssertNotNil(found?.endedAt)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - saveNotes writes both files

    func testSaveNotesWritesBothFiles() async {
        let sessionID = "test_notes_session"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: Date())],
            startedAt: Date()
        )

        let template = TemplateSnapshot(
            id: UUID(), name: "Test", icon: "star", systemPrompt: "Be helpful"
        )
        let notes = GeneratedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Test Notes\n\nContent here."
        )

        await repo.saveNotes(sessionID: sessionID, notes: notes)

        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("notes.md").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("notes.meta.json").path
        ))

        let loaded = await repo.loadNotes(sessionID: sessionID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.markdown, "# Test Notes\n\nContent here.")
        XCTAssertEqual(loaded?.template.name, "Test")

        // hasNotes should be updated in session.json
        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.hasNotes, true)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - listSessions returns all sessions

    func testListSessionsReturnsAllSessions() async {
        await repo.seedSession(
            id: "session_a",
            records: [SessionRecord(speaker: .you, text: "A", timestamp: Date())],
            startedAt: Date(timeIntervalSinceNow: -100)
        )
        await repo.seedSession(
            id: "session_b",
            records: [SessionRecord(speaker: .them, text: "B", timestamp: Date())],
            startedAt: Date()
        )

        let sessions = await repo.listSessions()
        XCTAssertTrue(sessions.contains(where: { $0.id == "session_a" }))
        XCTAssertTrue(sessions.contains(where: { $0.id == "session_b" }))

        // Should be sorted newest first
        if let aIdx = sessions.firstIndex(where: { $0.id == "session_a" }),
           let bIdx = sessions.firstIndex(where: { $0.id == "session_b" }) {
            XCTAssertLessThan(bIdx, aIdx)
        }

        await repo.deleteSession(sessionID: "session_a")
        await repo.deleteSession(sessionID: "session_b")
    }

    // MARK: - loadSession returns transcript and notes

    func testLoadSessionReturnsTranscriptAndNotes() async {
        let sessionID = "session_load_test"
        let records = [
            SessionRecord(speaker: .you, text: "First", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Second", timestamp: Date()),
        ]

        let template = TemplateSnapshot(
            id: UUID(), name: "Generic", icon: "doc", systemPrompt: "Notes"
        )
        let notes = GeneratedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Notes"
        )

        await repo.seedSession(
            id: sessionID,
            records: records,
            startedAt: Date(),
            notes: notes
        )

        let detail = await repo.loadSession(id: sessionID)
        XCTAssertEqual(detail.transcript.count, 2)
        XCTAssertEqual(detail.transcript[0].text, "First")
        XCTAssertNotNil(detail.notes)
        XCTAssertEqual(detail.notes?.markdown, "# Notes")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - renameSession updates metadata

    func testRenameSessionUpdatesMetadata() async {
        let sessionID = "session_rename_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            title: "Original"
        )

        await repo.renameSession(sessionID: sessionID, title: "Renamed")

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.title, "Renamed")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - deleteSession removes directory

    func testDeleteSessionRemovesDirectory() async {
        let sessionID = "session_delete_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Delete me", timestamp: Date())],
            startedAt: Date()
        )

        let before = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertFalse(before.isEmpty)

        await repo.deleteSession(sessionID: sessionID)

        let after = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertTrue(after.isEmpty)

        let sessions = await repo.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == sessionID }))
    }

    // MARK: - Legacy sessions readable

    func testLegacySessionsReadable() async {
        // Create a legacy-format session: flat .jsonl + .meta.json in sessions/
        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "session_2025-01-15_10-00-00"

        // Write legacy JSONL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = SessionRecord(
            speaker: .them, text: "Legacy hello",
            timestamp: Date(timeIntervalSince1970: 1_705_312_800)
        )
        let jsonlData = try! encoder.encode(record)
        let jsonlContent = String(data: jsonlData, encoding: .utf8)! + "\n"
        let jsonlURL = sessionsDir.appendingPathComponent("\(sessionID).jsonl")
        try! jsonlContent.write(to: jsonlURL, atomically: true, encoding: .utf8)

        // Write legacy sidecar
        let sidecar = SessionSidecar(
            index: SessionIndex(
                id: sessionID,
                startedAt: Date(timeIntervalSince1970: 1_705_312_800),
                title: "Legacy Meeting",
                utteranceCount: 1,
                hasNotes: false
            ),
            notes: nil
        )
        let sidecarData = try! encoder.encode(sidecar)
        let sidecarURL = sessionsDir.appendingPathComponent("\(sessionID).meta.json")
        try! sidecarData.write(to: sidecarURL)

        // Verify legacy session appears in listing
        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Legacy Meeting")

        // Verify transcript loads
        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.text, "Legacy hello")

        // Cleanup
        try? FileManager.default.removeItem(at: jsonlURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    // MARK: - FileHandle stays open during recording

    func testFileHandleStaysOpenDuringRecording() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        // Write multiple utterances - FileHandle should remain open
        for i in 1...10 {
            let utterance = Utterance(text: "Message \(i)", speaker: .you, timestamp: Date())
            await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        }

        // All should be written
        await repo.endSession()
        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 10)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - exportPlainText

    func testExportPlainText() async {
        let sessionID = "session_export_test"
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)

        await repo.seedSession(
            id: sessionID,
            records: [
                SessionRecord(speaker: .you, text: "Hello there", timestamp: startDate),
                SessionRecord(speaker: .them, text: "Hi back", timestamp: startDate.addingTimeInterval(10)),
            ],
            startedAt: startDate
        )

        let text = await repo.exportPlainText(sessionID: sessionID)
        XCTAssertTrue(text.contains("OpenOats"))
        XCTAssertTrue(text.contains("You: Hello there"))
        XCTAssertTrue(text.contains("Them: Hi back"))

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - saveFinalTranscript

    func testSaveFinalTranscript() async {
        let sessionID = "session_final_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Live", timestamp: Date())],
            startedAt: Date()
        )

        let finalRecords = [
            SessionRecord(speaker: .you, text: "Final A", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Final B", timestamp: Date()),
        ]
        await repo.saveFinalTranscript(sessionID: sessionID, records: finalRecords)

        // loadTranscript should prefer final
        let loaded = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "Final A")

        // loadLiveTranscript should still return original
        let live = await repo.loadLiveTranscript(sessionID: sessionID)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].text, "Live")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - moveToRecentlyDeleted

    func testMoveToRecentlyDeleted() async {
        let sessionID = "session_soft_delete"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date()
        )

        await repo.moveToRecentlyDeleted(sessionID: sessionID)

        let sessions = await repo.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == sessionID }))
    }

    // MARK: - End session clears state

    func testEndSessionClearsCurrentID() async {
        let handle = await repo.startSession()
        let id = await repo.getCurrentSessionID()
        XCTAssertNotNil(id)

        await repo.endSession()
        let idAfter = await repo.getCurrentSessionID()
        XCTAssertNil(idAfter)

        await repo.deleteSession(sessionID: handle.sessionID)
    }

    // MARK: - Load for nonexistent session

    func testLoadTranscriptForNonexistentSession() async {
        let transcript = await repo.loadTranscript(sessionID: "nonexistent_xyz")
        XCTAssertTrue(transcript.isEmpty)
    }

    func testLoadNotesForNonexistentSession() async {
        let notes = await repo.loadNotes(sessionID: "nonexistent_xyz")
        XCTAssertNil(notes)
    }

    // MARK: - SessionRecord encoding roundtrip

    func testSessionRecordRoundTrip() throws {
        let record = SessionRecord(
            speaker: .you,
            text: "Hello there",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            suggestions: ["Try asking about X"],
            kbHits: ["doc.md"],
            cleanedText: "Hello there."
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
        XCTAssertEqual(decoded.cleanedText, "Hello there.")
    }
}
