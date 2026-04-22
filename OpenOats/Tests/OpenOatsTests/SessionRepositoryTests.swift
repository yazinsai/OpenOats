import XCTest
@testable import OpenOatsKit

final class SessionRepositoryTests: XCTestCase {

    private var repo: SessionRepository!
    private var rootDir: URL!

    private func makeCalendarEvent() -> CalendarEvent {
        CalendarEvent(
            id: "event-123",
            title: "Customer Sync",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            calendarID: "calendar-123",
            calendarTitle: "Customer Meetings",
            calendarColorHex: "#3366FF",
            organizer: "Aly",
            participants: [
                Participant(name: "Aly", email: "aly@example.com"),
                Participant(name: "Nima", email: "nima@example.com"),
            ],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/customer-sync")
        )
    }

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

    func testStartSessionPersistsInitialMeetingIdentity() async {
        let calendarEvent = makeCalendarEvent()
        let handle = await repo.startSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: "Customer Sync",
                calendarEvent: calendarEvent
            )
        )

        let session = await repo.loadSession(id: handle.sessionID)
        XCTAssertEqual(session.index.title, "Customer Sync")
        XCTAssertEqual(session.calendarEvent?.id, calendarEvent.id)
        XCTAssertEqual(session.calendarEvent?.calendarTitle, calendarEvent.calendarTitle)

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
        let calendarEvent = makeCalendarEvent()

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
                utterances: [utterance],
                calendarEvent: calendarEvent
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

        let session = await repo.loadSession(id: sessionID)
        XCTAssertEqual(session.calendarEvent?.title, "Customer Sync")
        XCTAssertEqual(session.calendarEvent?.calendarID, "calendar-123")
        XCTAssertEqual(session.calendarEvent?.calendarTitle, "Customer Meetings")
        XCTAssertEqual(session.calendarEvent?.calendarColorHex, "#3366FF")
        XCTAssertEqual(session.calendarEvent?.participants.count, 2)

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

    func testSaveNotesMirrorsToNotesFolderPath() async {
        let exportDir = rootDir.appendingPathComponent("exported_notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        
        await repo.setNotesFolderPath(exportDir)
        
        let sessionID = "test_mirror_session"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: Date())],
            startedAt: Date(),
            title: "Mirror Meeting"
        )

        let template = TemplateSnapshot(
            id: UUID(), name: "Mirror", icon: "star", systemPrompt: "Be helpful"
        )
        let notes = GeneratedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Mirror Notes\n\nContent here."
        )

        await repo.saveNotes(sessionID: sessionID, notes: notes)
        
        // Poll for detached task to complete (up to 2 seconds)
        var didMirror = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let contents = try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
            if contents?.contains(where: { $0.lastPathComponent.contains("mirror-meeting") && $0.pathExtension == "md" }) ?? false {
                didMirror = true
                break
            }
        }
        
        XCTAssertTrue(didMirror, "Background mirror task did not complete in time")
        
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

    func testUpdateSessionFolderPersistsNormalizedPath() async {
        let sessionID = "session_folder_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: Date())],
            startedAt: Date()
        )

        await repo.updateSessionFolder(sessionID: sessionID, folderPath: " Work // 1:1s / ./ Bertie / ")

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.folderPath, "Work/1:1s/Bertie")

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
        let initialStart = Date(timeIntervalSince1970: 100)
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Live", timestamp: initialStart)],
            startedAt: initialStart
        )

        let finalStart = Date(timeIntervalSince1970: 200)
        let finalRecords = [
            SessionRecord(speaker: .you, text: "Final A", timestamp: finalStart),
            SessionRecord(speaker: .them, text: "Final B", timestamp: finalStart.addingTimeInterval(12)),
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

        let sessions = await repo.listSessions()
        let saved = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(saved?.utteranceCount, finalRecords.count)
        XCTAssertEqual(saved?.startedAt, finalStart)
        XCTAssertEqual(saved?.endedAt, finalStart.addingTimeInterval(12))

        await repo.deleteSession(sessionID: sessionID)
    }

    func testSaveFinalTranscriptPreservesCalendarEvent() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID
        let startDate = Date(timeIntervalSince1970: 1_000)
        let calendarEvent = makeCalendarEvent()

        let utterance = Utterance(text: "Live", speaker: .you, timestamp: startDate)
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)

        await repo.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: startDate.addingTimeInterval(30),
                utteranceCount: 1,
                title: "Customer Sync",
                language: "en-GB",
                meetingApp: "Zoom",
                engine: "parakeetV2",
                templateSnapshot: nil,
                utterances: [utterance],
                calendarEvent: calendarEvent
            )
        )

        let finalRecords = [
            SessionRecord(speaker: .you, text: "Final A", timestamp: startDate),
            SessionRecord(speaker: .them, text: "Final B", timestamp: startDate.addingTimeInterval(12)),
        ]
        await repo.saveFinalTranscript(sessionID: sessionID, records: finalRecords)

        let session = await repo.loadSession(id: sessionID)
        XCTAssertEqual(session.calendarEvent?.id, calendarEvent.id)
        XCTAssertEqual(session.calendarEvent?.title, calendarEvent.title)
        XCTAssertEqual(session.calendarEvent?.calendarTitle, calendarEvent.calendarTitle)

        await repo.deleteSession(sessionID: sessionID)
    }

    func testReconcileGhostSessionMergesCalendarEventIntoRecentRealSession() async {
        let calendarEvent = makeCalendarEvent()
        let realStartedAt = Date().addingTimeInterval(-180)
        let realEndedAt = realStartedAt.addingTimeInterval(60)

        await repo.seedSession(
            id: "session_real",
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: realStartedAt)],
            startedAt: realStartedAt,
            endedAt: realEndedAt,
            title: "Customer Sync"
        )

        let ghostHandle = await repo.startSession()
        await repo.finalizeSession(
            sessionID: ghostHandle.sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: realEndedAt.addingTimeInterval(120),
                utteranceCount: 0,
                title: "Customer Sync",
                language: nil,
                meetingApp: nil,
                engine: nil,
                templateSnapshot: nil,
                utterances: [],
                calendarEvent: calendarEvent
            )
        )

        let mergedSessionID = await repo.reconcileGhostSession(sessionID: ghostHandle.sessionID)

        XCTAssertEqual(mergedSessionID, "session_real")
        let sessions = await repo.listSessions()
        XCTAssertEqual(sessions.filter { $0.title == "Customer Sync" }.map(\.id), ["session_real"])

        let mergedDetail = await repo.loadSession(id: "session_real")
        XCTAssertEqual(mergedDetail.calendarEvent?.id, calendarEvent.id)

        await repo.deleteSession(sessionID: "session_real")
    }

    func testReconcileGhostSessionKeepsEmptySessionWhenAudioArtifactsExist() async throws {
        let calendarEvent = makeCalendarEvent()
        let realStartedAt = Date().addingTimeInterval(-180)
        let realEndedAt = realStartedAt.addingTimeInterval(60)

        await repo.seedSession(
            id: "session_real",
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: realStartedAt)],
            startedAt: realStartedAt,
            endedAt: realEndedAt,
            title: "Customer Sync"
        )

        let ghostHandle = await repo.startSession()
        await repo.finalizeSession(
            sessionID: ghostHandle.sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: realEndedAt.addingTimeInterval(120),
                utteranceCount: 0,
                title: "Customer Sync",
                language: nil,
                meetingApp: nil,
                engine: nil,
                templateSnapshot: nil,
                utterances: [],
                calendarEvent: calendarEvent
            )
        )

        let audioDir = rootDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(ghostHandle.sessionID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("mic".utf8).write(to: audioDir.appendingPathComponent("mic.caf"), options: .atomic)

        let mergedSessionID = await repo.reconcileGhostSession(sessionID: ghostHandle.sessionID)

        XCTAssertNil(mergedSessionID)
        let sessions = await repo.listSessions()
        XCTAssertTrue(sessions.contains(where: { $0.id == ghostHandle.sessionID }))
        let realDetail = await repo.loadSession(id: "session_real")
        XCTAssertNil(realDetail.calendarEvent)

        await repo.deleteSession(sessionID: ghostHandle.sessionID)
        await repo.deleteSession(sessionID: "session_real")
    }

    func testResumeAbandonedSessionReusesEmptyUnfinishedMeetingRow() async {
        let now = Date()
        let calendarEvent = CalendarEvent(
            id: "event-resume",
            title: "Customer Sync",
            startDate: now.addingTimeInterval(-120),
            endDate: now.addingTimeInterval(780),
            calendarID: "calendar-123",
            calendarTitle: "Customer Meetings",
            calendarColorHex: "#3366FF",
            organizer: "Aly",
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/customer-sync")
        )
        let originalHandle = await repo.startSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: calendarEvent.title,
                calendarEvent: calendarEvent
            )
        )
        await repo.endSession()

        let resumedHandle = await repo.resumeAbandonedSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: calendarEvent.title,
                calendarEvent: calendarEvent
            )
        )

        XCTAssertEqual(resumedHandle?.sessionID, originalHandle.sessionID)
        let currentSessionID = await repo.getCurrentSessionID()
        XCTAssertEqual(currentSessionID, originalHandle.sessionID)

        let utterance = Utterance(text: "Recovered recording", speaker: .you, timestamp: Date())
        await repo.appendLiveUtterance(sessionID: originalHandle.sessionID, utterance: utterance)
        await repo.endSession()

        let liveTranscript = await repo.loadLiveTranscript(sessionID: originalHandle.sessionID)
        XCTAssertEqual(liveTranscript.count, 1)
        XCTAssertEqual(liveTranscript.first?.text, "Recovered recording")

        await repo.deleteSession(sessionID: originalHandle.sessionID)
    }

    func testResumeAbandonedSessionSkipsRowsWithTranscriptArtifacts() async {
        let now = Date()
        let calendarEvent = CalendarEvent(
            id: "event-resume-skip",
            title: "Customer Sync",
            startDate: now.addingTimeInterval(-120),
            endDate: now.addingTimeInterval(780),
            calendarID: "calendar-123",
            calendarTitle: "Customer Meetings",
            calendarColorHex: "#3366FF",
            organizer: "Aly",
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/customer-sync")
        )
        let originalHandle = await repo.startSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: calendarEvent.title,
                calendarEvent: calendarEvent
            )
        )

        let utterance = Utterance(text: "Existing transcript", speaker: .you, timestamp: Date())
        await repo.appendLiveUtterance(sessionID: originalHandle.sessionID, utterance: utterance)
        await repo.endSession()

        let resumedHandle = await repo.resumeAbandonedSession(
            config: SessionStartConfig(
                templateSnapshot: nil,
                title: calendarEvent.title,
                calendarEvent: calendarEvent
            )
        )

        XCTAssertNil(resumedHandle)

        await repo.deleteSession(sessionID: originalHandle.sessionID)
    }

    func testBatchMetaPersistsEffectiveSystemSampleRate() async {
        let sessionID = "session_batch_meta"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Live", timestamp: Date())],
            startedAt: Date()
        )

        let tempDir = rootDir.appendingPathComponent("batch_temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let micURL = tempDir.appendingPathComponent("mic.caf")
        let sysURL = tempDir.appendingPathComponent("sys.caf")
        FileManager.default.createFile(atPath: micURL.path, contents: Data())
        FileManager.default.createFile(atPath: sysURL.path, contents: Data())

        await repo.stashAudioForBatch(
            sessionID: sessionID,
            micURL: micURL,
            sysURL: sysURL,
            anchors: BatchAnchors(
                micStartDate: Date(timeIntervalSince1970: 10),
                sysStartDate: Date(timeIntervalSince1970: 20),
                micAnchors: [(frame: 0, date: Date(timeIntervalSince1970: 10))],
                sysAnchors: [(frame: 0, date: Date(timeIntervalSince1970: 20))],
                sysEffectiveSampleRate: 24_000
            )
        )

        let meta = await repo.loadBatchMeta(sessionID: sessionID)
        XCTAssertEqual(meta?.sysEffectiveSampleRate, 24_000)

        await repo.deleteSession(sessionID: sessionID)
    }

    func testUpdateSessionTagsPreservesInternalGranolaTag() async {
        let sessionID = "session_granola_tags"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Live", timestamp: Date())],
            startedAt: Date()
        )

        await repo.updateSessionSource(
            sessionID: sessionID,
            source: "granola",
            tags: ["granola:not_123"]
        )
        await repo.updateSessionTags(sessionID: sessionID, tags: ["team", "follow-up"])

        let sessions = await repo.listSessions()
        let saved = sessions.first(where: { $0.id == sessionID })

        XCTAssertEqual(saved?.source, "granola")
        XCTAssertEqual(saved?.tags ?? [], ["granola:not_123", "team", "follow-up"])

        await repo.deleteSession(sessionID: sessionID)
    }

    func testInitRetainsRecentBatchAudioForRerunWindow() async throws {
        let sessionID = "session_recent_batch_audio"
        let sessionDir = try makeSessionWithBatchAudio(sessionID: sessionID)
        try setModificationDate(
            Date().addingTimeInterval(-(6 * 24 * 3600)),
            forSessionDirectory: sessionDir
        )

        let freshRepo = SessionRepository(rootDirectory: rootDir)
        let urls = await freshRepo.batchAudioURLs(sessionID: sessionID)
        let meta = await freshRepo.loadBatchMeta(sessionID: sessionID)

        XCTAssertNotNil(urls.mic)
        XCTAssertNotNil(urls.sys)
        XCTAssertNotNil(meta)
    }

    func testInitCleansExpiredBatchAudioAfterRerunWindow() async throws {
        let sessionID = "session_expired_batch_audio"
        let sessionDir = try makeSessionWithBatchAudio(sessionID: sessionID)
        try setModificationDate(
            Date().addingTimeInterval(-(8 * 24 * 3600)),
            forSessionDirectory: sessionDir
        )

        let freshRepo = SessionRepository(rootDirectory: rootDir)
        let urls = await freshRepo.batchAudioURLs(sessionID: sessionID)
        let meta = await freshRepo.loadBatchMeta(sessionID: sessionID)

        XCTAssertNil(urls.mic)
        XCTAssertNil(urls.sys)
        XCTAssertNil(meta)
    }

    func testAudioSourcesExposeRawBatchAudioFiles() async throws {
        let sessionID = "session_batch_audio_sources"
        _ = try makeSessionWithBatchAudio(sessionID: sessionID)

        let sources = await repo.audioSources(for: sessionID)
        let defaultAudioURL = await repo.audioFileURL(for: sessionID)

        XCTAssertEqual(sources.map(\.kind), [.system, .microphone])
        XCTAssertEqual(sources.first?.url.lastPathComponent, "sys.caf")
        XCTAssertEqual(sources.last?.url.lastPathComponent, "mic.caf")
        XCTAssertEqual(defaultAudioURL?.lastPathComponent, "sys.caf")
    }

    func testAudioSourcesIgnoreTranscriptBackupFiles() async throws {
        let sessionID = "session_ignores_transcript_backup"
        let sessionDir = try makeSessionWithBatchAudio(sessionID: sessionID)
        let backupURL = sessionDir.appendingPathComponent("transcript.live.jsonl.pre-cleanup.bak")
        try Data().write(to: backupURL, options: .atomic)

        let sources = await repo.audioSources(for: sessionID)

        XCTAssertEqual(sources.map(\.kind), [.system, .microphone])
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

    private func makeSessionWithBatchAudio(sessionID: String) throws -> URL {
        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        let audioDir = sessionDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let metadata = SessionMetadata(
            id: sessionID,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            templateSnapshot: nil,
            title: "Batch Audio",
            utteranceCount: 1,
            hasNotes: false,
            language: "en-GB",
            meetingApp: nil,
            engine: "parakeetV2",
            tags: nil,
            source: nil
        )
        let data = try JSONEncoder.iso8601Encoder.encode(metadata)
        try data.write(to: sessionDir.appendingPathComponent("session.json"), options: .atomic)
        try Data().write(to: sessionDir.appendingPathComponent("transcript.live.jsonl"), options: .atomic)

        try Data("mic".utf8).write(to: audioDir.appendingPathComponent("mic.caf"), options: .atomic)
        try Data("sys".utf8).write(to: audioDir.appendingPathComponent("sys.caf"), options: .atomic)

        let batchMeta = BatchMeta(
            micStartDate: Date(timeIntervalSince1970: 10),
            sysStartDate: Date(timeIntervalSince1970: 20),
            micAnchors: [.init(frame: 0, date: Date(timeIntervalSince1970: 10))],
            sysAnchors: [.init(frame: 0, date: Date(timeIntervalSince1970: 20))],
            sysEffectiveSampleRate: 24_000
        )
        let metaData = try JSONEncoder.iso8601Encoder.encode(batchMeta)
        try metaData.write(to: audioDir.appendingPathComponent("batch-meta.json"), options: .atomic)

        return sessionDir
    }

    private func setModificationDate(_ date: Date, forSessionDirectory sessionDir: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sessionDir.path)
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
