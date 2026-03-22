import XCTest
@testable import OpenOatsKit

final class SessionRepositoryTests: XCTestCase {
    private var repository: SessionRepository!
    private var rootDirectory: URL!

    override func setUp() async throws {
        rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsRepositoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        repository = SessionRepository(rootDirectory: rootDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDirectory)
        repository = nil
        rootDirectory = nil
    }

    func testStartAppendFinalizeAndLoadCanonicalSession() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let handle = await repository.startSession(
            config: SessionStartConfig(
                startedAt: startedAt,
                templateSnapshot: nil,
                title: "Repo Test",
                meetingApp: "Zoom",
                engine: "parakeetV2"
            )
        )

        await repository.appendLiveUtterance(
            sessionID: handle.id,
            utterance: Utterance(
                text: "Hello from test",
                speaker: .them,
                timestamp: startedAt
            )
        )
        await repository.finalizeSession(
            sessionID: handle.id,
            finalMetadata: SessionFinalizeMetadata(
                endedAt: startedAt.addingTimeInterval(60),
                title: "Repo Test",
                meetingApp: "Zoom",
                engine: "parakeetV2"
            )
        )

        let summaries = await repository.listSessions()
        let summary = try XCTUnwrap(summaries.first(where: { $0.id == handle.id }))
        XCTAssertEqual(summary.utteranceCount, 1)
        XCTAssertEqual(summary.title, "Repo Test")

        let detail = await repository.loadSession(id: handle.id)
        XCTAssertEqual(detail.liveTranscript.count, 1)
        XCTAssertEqual(detail.liveTranscript.first?.text, "Hello from test")
        XCTAssertNil(detail.notes)
    }

    func testSaveNotesMarksSessionAndLoadsNotes() async {
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let handle = await repository.startSession(config: SessionStartConfig(startedAt: startedAt))
        await repository.finalizeSession(
            sessionID: handle.id,
            finalMetadata: SessionFinalizeMetadata(
                endedAt: startedAt.addingTimeInterval(30),
                title: nil,
                meetingApp: nil,
                engine: nil
            )
        )

        let template = TemplateSnapshot(
            id: UUID(),
            name: "Test Template",
            icon: "star",
            systemPrompt: "Be helpful"
        )
        let notes = EnhancedNotes(
            template: template,
            generatedAt: startedAt.addingTimeInterval(40),
            markdown: "# Notes\n\nSummary"
        )
        await repository.saveNotes(sessionID: handle.id, notes: notes)

        let detail = await repository.loadSession(id: handle.id)
        XCTAssertEqual(detail.notes?.markdown, "# Notes\n\nSummary")
        XCTAssertEqual(detail.notes?.template.name, "Test Template")

        let summaries = await repository.listSessions()
        XCTAssertTrue(summaries.first(where: { $0.id == handle.id })?.hasNotes ?? false)
    }

    func testDeleteSessionRemovesCanonicalFiles() async {
        let handle = await repository.startSession(config: SessionStartConfig())
        await repository.appendLiveUtterance(
            sessionID: handle.id,
            utterance: Utterance(text: "Delete me", speaker: .them)
        )
        await repository.deleteSession(sessionID: handle.id)

        let summaries = await repository.listSessions()
        XCTAssertFalse(summaries.contains(where: { $0.id == handle.id }))
        let detail = await repository.loadSession(id: handle.id)
        XCTAssertTrue(detail.liveTranscript.isEmpty)
    }

    func testLegacySessionIsImportedOnMutation() async throws {
        let sessionID = "session_2026-01-01_10-00-00"
        let sessionsDirectory = rootDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let record = SessionRecord(
            speaker: .them,
            text: "Legacy transcript",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transcriptData = try encoder.encode(record) + Data("\n".utf8)
        try transcriptData.write(
            to: sessionsDirectory.appendingPathComponent("\(sessionID).jsonl"),
            options: .atomic
        )

        let sidecar = SessionSidecar(
            index: SessionIndex(
                id: sessionID,
                startedAt: Date(timeIntervalSince1970: 1_000_000),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Legacy",
                utteranceCount: 1,
                hasNotes: false,
                meetingApp: nil,
                engine: nil
            ),
            notes: nil
        )
        let sidecarData = try encoder.encode(sidecar)
        try sidecarData.write(
            to: sessionsDirectory.appendingPathComponent("\(sessionID).meta.json"),
            options: .atomic
        )

        await repository.renameSession(sessionID: sessionID, title: "Imported Legacy")

        let detail = await repository.loadSession(id: sessionID)
        XCTAssertEqual(detail.summary.title, "Imported Legacy")
        XCTAssertEqual(detail.liveTranscript.count, 1)

        let canonicalSessionJSON = sessionsDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalSessionJSON.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsDirectory.appendingPathComponent("\(sessionID).jsonl").path))
    }
}
