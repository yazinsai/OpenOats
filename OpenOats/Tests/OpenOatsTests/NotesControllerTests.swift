import XCTest
@testable import OpenOatsKit

@MainActor
final class NotesControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsNotesControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func makeSettings(notesDirectory: URL) -> AppSettings {
        let suiteName = "com.openoats.tests.notescontroller.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(notesDirectory.path, forKey: "notesFolderPath")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")
        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: notesDirectory,
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    private func seedSession(
        coordinator: AppCoordinator,
        sessionID: String = "session_test_001",
        title: String = "Test Meeting",
        utterances: [SessionRecord]? = nil,
        calendarEvent: CalendarEvent? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async {
        let records = utterances ?? [
            SessionRecord(speaker: .you, text: "Hello there.", timestamp: startedAt),
            SessionRecord(speaker: .them, text: "Hi, how are you?", timestamp: startedAt.addingTimeInterval(10)),
            SessionRecord(speaker: .you, text: "Great, let's discuss the plan.", timestamp: startedAt.addingTimeInterval(20)),
        ]

        await coordinator.sessionRepository.seedSession(
            id: sessionID,
            records: records,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
            ),
            title: title
        )
        if let calendarEvent {
            await coordinator.sessionRepository.finalizeSession(
                sessionID: sessionID,
                metadata: SessionFinalizeMetadata(
                    endedAt: startedAt.addingTimeInterval(60),
                    utteranceCount: records.count,
                    title: title,
                    language: nil,
                    meetingApp: nil,
                    engine: nil,
                    templateSnapshot: coordinator.templateStore.snapshot(
                        of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
                    ),
                    utterances: records.map {
                        Utterance(
                            text: $0.text,
                            speaker: $0.speaker,
                            timestamp: $0.timestamp,
                            cleanedText: $0.cleanedText
                        )
                    },
                    calendarEvent: calendarEvent
                )
            )
        }
        await coordinator.loadHistory()
    }

    private func makeController(root: URL, settings: AppSettings? = nil) -> (NotesController, AppCoordinator) {
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "# Test Notes\n\n## Summary\nTest summary.")),
            transcriptStore: TranscriptStore()
        )
        let controller = NotesController(coordinator: coordinator, settings: settings)
        return (controller, coordinator)
    }

    private func makeController(
        root: URL,
        settings: AppSettings? = nil,
        notesEngine: NotesEngine
    ) -> (NotesController, AppCoordinator) {
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: notesEngine,
            transcriptStore: TranscriptStore()
        )
        let controller = NotesController(coordinator: coordinator, settings: settings)
        return (controller, coordinator)
    }

    // MARK: - Tests

    func testSelectSessionLoadsTranscriptAndNotes() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_select"

        await seedSession(coordinator: coordinator, sessionID: sessionID)

        controller.selectSession(sessionID)

        // Wait for async load to complete
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
        XCTAssertEqual(controller.state.loadedTranscript.count, 3)
        XCTAssertNil(controller.state.loadedNotes, "No notes should exist before generation")
    }

    func testSelectSessionLoadsCalendarContext() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_calendar_context"
        let calendarEvent = CalendarEvent(
            id: "evt-1",
            title: "Design Review",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: "Alice",
            participants: [
                Participant(name: "Alice", email: "alice@example.com"),
                Participant(name: "Bob", email: "bob@example.com"),
            ],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/design-review")
        )

        await seedSession(
            coordinator: coordinator,
            sessionID: sessionID,
            title: "Design Review",
            calendarEvent: calendarEvent
        )

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.loadedCalendarEvent?.title, "Design Review")
        XCTAssertEqual(controller.state.loadedCalendarEvent?.participants.count, 2)
    }

    func testSelectSessionLoadsRawAudioSources() async throws {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_raw_audio_sources"

        await seedSession(coordinator: coordinator, sessionID: sessionID)

        let audioDir = coordinator.sessionRepository.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("sys".utf8).write(to: audioDir.appendingPathComponent("sys.caf"))
        try Data("mic".utf8).write(to: audioDir.appendingPathComponent("mic.caf"))

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.availableAudioSources.map(\.kind), [.system, .microphone])
        XCTAssertEqual(controller.state.audioFileURL?.lastPathComponent, "sys.caf")
    }

    func testSelectSessionLoadsBatchTranscriptActionsWhenArtifactsExist() async throws {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_batch_transcript_actions"

        await seedSession(coordinator: coordinator, sessionID: sessionID)

        let audioDir = coordinator.sessionRepository.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("sys".utf8).write(to: audioDir.appendingPathComponent("sys.caf"))
        try Data("live".utf8).write(
            to: coordinator.sessionRepository.sessionsDirectoryURL
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("transcript.pre-batch.jsonl")
        )

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(controller.state.canRetranscribeSelectedSession)
        XCTAssertTrue(controller.state.hasOriginalTranscriptBackup)
    }

    func testRestoreOriginalTranscriptReloadsSelectedSession() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_restore_transcript"

        await seedSession(
            coordinator: coordinator,
            sessionID: sessionID,
            utterances: [SessionRecord(speaker: .you, text: "Original live", timestamp: Date(timeIntervalSince1970: 1_700_000_000))]
        )

        await coordinator.sessionRepository.saveFinalTranscript(
            sessionID: sessionID,
            records: [SessionRecord(speaker: .them, text: "Batch overwrite", timestamp: Date(timeIntervalSince1970: 1_700_000_030))],
            backupCurrentTranscript: true
        )
        await coordinator.loadHistory()

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.loadedTranscript.map(\.text), ["Batch overwrite"])
        XCTAssertTrue(controller.state.hasOriginalTranscriptBackup)

        controller.restoreOriginalTranscript()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.state.loadedTranscript.map(\.text), ["Original live"])
    }

    func testAddManualTranscriptPersistsSourceAndReloadsTranscript() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_add_manual_transcript"

        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)

        controller.addManualTranscript("You: Hello there.\nThem: Hi, how are you?")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.state.loadedTranscript.map(\.text), ["Hello there.", "Hi, how are you?"])
        XCTAssertEqual(controller.state.loadedTranscript.map(\.speaker), [.you, .them])

        let rawSource = await coordinator.sessionRepository.loadManualTranscriptSource(sessionID: sessionID)
        XCTAssertEqual(rawSource, "You: Hello there.\nThem: Hi, how are you?")
    }

    func testAddManualTranscriptStripsTimestampsAndParsesRemoteSpeakers() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_manual_transcript_parsing"

        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.addManualTranscript("""
        [00:10] You: Kickoff
        00:20 Speaker 2: Response
        Loose closing line
        """)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.state.loadedTranscript.map(\.text), ["Kickoff", "Response", "Loose closing line"])
        XCTAssertEqual(controller.state.loadedTranscript.map(\.speaker), [.you, .remote(2), .them])
    }

    func testPrepareManualTranscriptSessionCreatesAndSelectsPastMeetingSession() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)
        let calendarEvent = CalendarEvent(
            id: "evt-manual-past",
            title: "Past Meeting",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            calendarTitle: "WFF",
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        settings.setMeetingFamilyFolderPreference("Work", for: calendarEvent)
        controller.showMeetingFamily(for: calendarEvent)

        let shouldPrompt = await controller.prepareManualTranscriptSession(for: calendarEvent)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(shouldPrompt)
        XCTAssertNotNil(controller.state.selectedSessionID)
        XCTAssertEqual(controller.state.loadedCalendarEvent?.id, calendarEvent.id)
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)

        if let sessionID = controller.state.selectedSessionID {
            let session = await coordinator.sessionRepository.loadSession(id: sessionID)
            XCTAssertEqual(session.index.folderPath, "Work")
            XCTAssertEqual(session.index.source, "manual")
        }
    }

    func testPrepareManualTranscriptSessionDoesNotPromptWhenTranscriptAlreadyExists() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let calendarEvent = CalendarEvent(
            id: "evt-existing-past",
            title: "Recorded Past Meeting",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            calendarTitle: "WFF",
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        await seedSession(
            coordinator: coordinator,
            sessionID: "session_existing_past",
            title: calendarEvent.title,
            utterances: [SessionRecord(speaker: .you, text: "Existing transcript", timestamp: calendarEvent.startDate)],
            calendarEvent: calendarEvent
        )
        controller.showMeetingFamily(for: calendarEvent)

        let shouldPrompt = await controller.prepareManualTranscriptSession(for: calendarEvent)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertFalse(shouldPrompt)
        XCTAssertEqual(controller.state.loadedTranscript.map(\.text), ["Existing transcript"])
    }

    func testGenerateNotesUpdatesStatus() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_generate"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        // Scripted engine completes synchronously within Task, give it time
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertNotNil(controller.state.loadedNotes)
        XCTAssertEqual(controller.state.notesGenerationStatus, .completed)
        XCTAssertTrue(controller.state.loadedNotes?.markdown.contains("Test Notes") ?? false)
    }

    func testGenerateNotesSavesNotes() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_patch"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // After generation, notes should be saved to session repository
        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(500))

        let savedNotes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
        XCTAssertNotNil(savedNotes)
        XCTAssertTrue(savedNotes?.markdown.contains("Test Notes") ?? false)
    }

    func testSaveManualNotesForSessionWithoutTranscript() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_manual_notes"

        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [])
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
        XCTAssertNil(controller.state.loadedNotes)

        controller.startManualNotesEditing()
        controller.updateManualNotesDraft("Manual notes for a failed recording.")
        controller.saveManualNotes()
        try? await Task.sleep(for: .milliseconds(250))

        let savedNotes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
        XCTAssertEqual(savedNotes?.markdown, "Manual notes for a failed recording.")
        XCTAssertEqual(controller.state.loadedNotes?.markdown, "Manual notes for a failed recording.")
        XCTAssertFalse(controller.hasUnsavedManualNotesChanges)
        XCTAssertFalse(controller.state.isEditingManualNotes)

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.manualNotesDraft, "Manual notes for a failed recording.")
        XCTAssertFalse(controller.state.isEditingManualNotes)
    }

    func testInsertImagePreservesUnsavedManualNotesDraft() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_manual_notes_image"

        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [])
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.startManualNotesEditing()
        controller.updateManualNotesDraft("Prep observations")
        controller.insertImage(imageData: Data([0x89, 0x50, 0x4E, 0x47]))
        try? await Task.sleep(for: .milliseconds(250))

        let savedNotes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
        XCTAssertNotNil(savedNotes)
        XCTAssertTrue(savedNotes?.markdown.contains("Prep observations") ?? false)
        XCTAssertTrue(savedNotes?.markdown.contains("![](images/") ?? false)
    }

    func testUnsavedManualNotesDraftSurvivesSessionSwitch() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "manual", title: "Manual Notes Session", utterances: [])
        await seedSession(coordinator: coordinator, sessionID: "other", title: "Other Session")

        controller.selectSession("manual")
        try? await Task.sleep(for: .milliseconds(200))
        controller.startManualNotesEditing()
        controller.updateManualNotesDraft("Unsaved draft that should survive switching away.")

        controller.selectSession("other")
        try? await Task.sleep(for: .milliseconds(200))
        controller.selectSession("manual")
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.manualNotesDraft, "Unsaved draft that should survive switching away.")
        XCTAssertTrue(controller.state.isEditingManualNotes)
        XCTAssertNil(controller.state.loadedNotes)
    }

    func testCleanupProgressMapsCorrectly() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_cleanup_mapping"

        // When idle with no transcript, should be idle initially
        XCTAssertEqual(controller.state.cleanupStatus, .idle)
        
        let cleanedRecord = SessionRecord(
            speaker: .you,
            text: "Raw text.",
            timestamp: Date(),
            cleanedText: "Cleaned text."
        )
        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [cleanedRecord])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Ensure cleanupStatus maps to completed since transcript has cleaned elements
        XCTAssertEqual(controller.state.cleanupStatus, .completed)
    }

    func testCleanupProgressIdleForUncleanedTranscript() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_cleanup_idle"
        
        let uncleanedRecord = SessionRecord(
            speaker: .you,
            text: "Raw text only.",
            timestamp: Date(),
            cleanedText: nil
        )
        await seedSession(coordinator: coordinator, sessionID: sessionID, utterances: [uncleanedRecord])

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Ensure cleanupStatus is idle since transcript has no cleaned elements
        XCTAssertEqual(controller.state.cleanupStatus, .idle)
    }

    func testRenameSessionUpdatesHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_rename"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "Original Title")
        await controller.loadHistory()

        let originalSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(originalSession?.title, "Original Title")

        controller.renameSession(sessionID: sessionID, newTitle: "New Title")
        try? await Task.sleep(for: .milliseconds(300))

        let renamedSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(renamedSession?.title, "New Title")
    }

    func testFolderGroupsSessionsByPath() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        await seedSession(
            coordinator: coordinator,
            sessionID: "session_root",
            title: "Inbox Meeting",
            startedAt: base
        )
        await seedSession(
            coordinator: coordinator,
            sessionID: "session_team",
            title: "Team Sync",
            startedAt: base.addingTimeInterval(300)
        )
        await seedSession(
            coordinator: coordinator,
            sessionID: "session_ones",
            title: "Bertie 1:1",
            startedAt: base.addingTimeInterval(150)
        )
        await coordinator.sessionRepository.updateSessionFolder(sessionID: "session_team", folderPath: "Work/Team")
        await coordinator.sessionRepository.updateSessionFolder(sessionID: "session_ones", folderPath: "Work/1:1s")
        await controller.loadHistory()

        XCTAssertTrue(controller.showsFolderSections)
        XCTAssertEqual(controller.rootFolderSessions.map(\.id), ["session_root"])
        XCTAssertEqual(controller.folderGroups.map(\.id), ["Work/Team", "Work/1:1s", "__root__"])
        XCTAssertEqual(controller.folderGroups.map(\.title), ["Work › Team", "Work › 1:1s", "My notes"])
    }

    func testDeleteSessionRemovesFromHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_delete"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await controller.loadHistory()
        XCTAssertTrue(controller.state.sessionHistory.contains { $0.id == sessionID })

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.deleteSession(sessionID: sessionID)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(controller.state.sessionHistory.contains { $0.id == sessionID })
        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
        XCTAssertNil(controller.state.loadedNotes)
    }

    func testOpenNotesSelectsCorrectSession() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_open"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        coordinator.queueSessionSelection(sessionID)

        await controller.onAppear()

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
    }

    func testOpenNotesCanExplicitlyClearSelection() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_clear_selection"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        coordinator.queueSessionSelection(nil)

        await controller.onAppear()

        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
    }

    func testOnAppearCanOpenMeetingHistoryRequest() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        await seedSession(coordinator: coordinator, sessionID: "session_payment_ops", title: "Payment Ops")

        let event = CalendarEvent(
            id: "evt_history",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
        coordinator.queueMeetingHistory(event)

        await controller.onAppear()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertEqual(controller.state.selectedMeetingHistory?.event.id, "evt_history")
        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["session_payment_ops"])
    }

    func testGenerateNotesPreservesGeneratedTopHeading() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_heading"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "Q4 Planning")
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(500))

        let markdown = controller.state.loadedNotes?.markdown ?? ""
        XCTAssertTrue(markdown.hasPrefix("# Test Notes\n\n"))
        XCTAssertFalse(markdown.contains("# Meeting Notes: Q4 Planning\n\n# Test Notes"))
    }

    func testShowMeetingHistoryLoadsMatchingSessionsAndNotePreviews() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "older", title: "Payment Ops Merchant stand up")
        await seedSession(coordinator: coordinator, sessionID: "newer", title: "Payment Ops / Merchant stand up")
        await seedSession(coordinator: coordinator, sessionID: "other", title: "Design Review")

        let template = coordinator.templateStore.snapshot(
            of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
        )
        let notes = GeneratedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Notes\n\n## Summary\nReviewed payout issues and next steps."
        )
        await coordinator.sessionRepository.saveNotes(sessionID: "newer", notes: notes)
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_payment_ops",
            title: "Payment Ops Merchant stand-up",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.selectedMeetingHistory?.event.id, "evt_payment_ops")
        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["newer", "older"])
        XCTAssertEqual(controller.state.meetingHistoryEntries.first?.notesPreview, "Reviewed payout issues and next steps.")
    }

    func testShowMeetingHistoryPublishesEntriesBeforePreviewHydrationFinishes() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "older", title: "Payment Ops Merchant stand up")
        await seedSession(coordinator: coordinator, sessionID: "newer", title: "Payment Ops / Merchant stand up")

        let template = coordinator.templateStore.snapshot(
            of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
        )
        let notes = GeneratedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Notes\n\n## Summary\nReviewed payout issues and next steps."
        )
        await coordinator.sessionRepository.saveNotes(sessionID: "newer", notes: notes)
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_payment_ops_immediate",
            title: "Payment Ops Merchant stand-up",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)

        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["newer", "older"])
        XCTAssertNil(controller.state.meetingHistoryEntries.first?.notesPreview)

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.state.meetingHistoryEntries.first?.notesPreview, "Reviewed payout issues and next steps.")
    }

    func testShowMeetingHistorySuggestsRenamedMeetingSeriesWhenExactHistoryIsEmpty() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        await seedSession(coordinator: coordinator, sessionID: "legacy1", title: "Payment Ops")
        await seedSession(coordinator: coordinator, sessionID: "legacy2", title: "Payment Ops")
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_renamed",
            title: "Payment Ops / Merchant standup",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(controller.state.meetingHistoryEntries.isEmpty)
        XCTAssertEqual(controller.state.relatedMeetingSuggestions.map(\.title), ["Payment Ops"])
        XCTAssertEqual(controller.state.relatedMeetingSuggestions.first?.sessionCount, 2)
    }

    func testShowMeetingHistorySuggestsSingleTokenRenameWhenTokenIsSpecific() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        await seedSession(coordinator: coordinator, sessionID: "legacy1", title: "Payment Ops")
        await seedSession(coordinator: coordinator, sessionID: "legacy2", title: "Payment Ops")
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_single_token",
            title: "Payment",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(controller.state.meetingHistoryEntries.isEmpty)
        XCTAssertEqual(controller.state.relatedMeetingSuggestions.map(\.title), ["Payment Ops"])
    }

    func testShowMeetingHistoryPrefersRecurringFamiliesForSingleTokenSuggestions() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        await seedSession(coordinator: coordinator, sessionID: "recurring1", title: "Payment Ops")
        await seedSession(coordinator: coordinator, sessionID: "recurring2", title: "Payment Ops")
        await seedSession(
            coordinator: coordinator,
            sessionID: "oneoff1",
            title: "Payment methods investigation for Adyen store setup"
        )
        await seedSession(
            coordinator: coordinator,
            sessionID: "oneoff2",
            title: "Payment Ops - payment redirection fraud"
        )
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_single_token_recurring_only",
            title: "Payment",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.relatedMeetingSuggestions.map(\.title), ["Payment Ops"])
    }

    func testShowMeetingHistoryKeepsOnlyDominantRecurringFamilyForSingleTokenSuggestions() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        for index in 0..<6 {
            await seedSession(coordinator: coordinator, sessionID: "ops_\(index)", title: "Payment Ops")
        }
        for index in 0..<2 {
            await seedSession(coordinator: coordinator, sessionID: "links_\(index)", title: "Payment Links")
        }
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_single_token_dominant",
            title: "Payment",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.relatedMeetingSuggestions.map(\.title), ["Payment Ops"])
    }

    func testLinkMeetingHistorySuggestionReloadsHistoryUsingAlias() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        await seedSession(coordinator: coordinator, sessionID: "legacy", title: "Payment Ops")
        await seedSession(coordinator: coordinator, sessionID: "other-variant", title: "Payment Ops Merchant")
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_renamed",
            title: "Payment Ops / Merchant standup",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(Set(controller.state.relatedMeetingSuggestions.map(\.title)), ["Payment Ops", "Payment Ops Merchant"])

        guard let suggestion = controller.state.relatedMeetingSuggestions.first(where: { $0.title == "Payment Ops" }) else {
            XCTFail("Expected related meeting suggestion")
            return
        }

        controller.linkMeetingHistorySuggestion(suggestion)
        XCTAssertEqual(controller.state.linkingMeetingSuggestionKey, suggestion.key)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["legacy"])
        XCTAssertNil(controller.state.linkingMeetingSuggestionKey)
        XCTAssertEqual(controller.state.relatedMeetingSuggestions.map(\.title), ["Payment Ops Merchant"])
    }

    func testMeetingHistoryPreviewStripsBulletsAndMarkdownMarkers() {
        let preview = NotesController.notesPreview(from: "# Notes\n\n- **Booking invoices page** - New interface for PMs")
        XCTAssertEqual(preview, "Booking invoices page - New interface for PMs")
    }

    func testSelectSessionAlsoLoadsMeetingFamilyHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "current", title: "Weekly Sync")
        await seedSession(coordinator: coordinator, sessionID: "older", title: "Weekly Sync")
        await seedSession(coordinator: coordinator, sessionID: "other", title: "Design Review")
        await controller.loadHistory()

        controller.selectSession("current")
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.selectedMeetingFamily?.title, "Weekly Sync")
        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["current", "older"])
    }

    func testShowCurrentMeetingFamilyOverviewClearsFocusedSessionButKeepsFamily() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "current", title: "Weekly Sync")
        await seedSession(coordinator: coordinator, sessionID: "older", title: "Weekly Sync")
        await controller.loadHistory()

        controller.selectSession("current")
        try? await Task.sleep(for: .milliseconds(250))
        controller.showCurrentMeetingFamilyOverview()

        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertEqual(controller.state.selectedMeetingFamily?.title, "Weekly Sync")
        XCTAssertEqual(controller.state.meetingHistoryEntries.map(\.session.id), ["current", "older"])
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
    }

    func testSelectSessionUsesMeetingFamilyTemplatePreferenceInsteadOfGenericTemplate() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        let event = CalendarEvent(
            id: "evt-weekly",
            title: "Weekly Sync",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
        settings.setMeetingFamilyTemplatePreference(TemplateStore.standUpID, for: event)

        await seedSession(
            coordinator: coordinator,
            sessionID: "weekly",
            title: "Weekly Sync",
            calendarEvent: event
        )
        await controller.loadHistory()

        controller.selectSession("weekly")
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(controller.state.selectedTemplate?.id, TemplateStore.standUpID)
    }

    func testApplyMeetingFamilyFolderPreferenceCanMoveExistingSessions() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let (controller, coordinator) = makeController(root: root, settings: settings)

        await seedSession(coordinator: coordinator, sessionID: "current", title: "Weekly All Hands")
        await seedSession(coordinator: coordinator, sessionID: "older", title: "Weekly All Hands")
        await controller.loadHistory()

        let event = CalendarEvent(
            id: "evt_family_folder",
            title: "Weekly All Hands",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        controller.showMeetingHistory(for: event)
        try? await Task.sleep(for: .milliseconds(250))

        controller.applyMeetingFamilyFolderPreference("Work/All Hands", moveExistingSessions: true)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(settings.meetingFamilyPreferences(for: event)?.folderPath, "Work/All Hands")
        XCTAssertEqual(
            controller.state.sessionHistory
                .filter { ["current", "older"].contains($0.id) }
                .map(\.folderPath),
            ["Work/All Hands", "Work/All Hands"]
        )
    }

    func testMeetingFamilyKnowledgeBaseCoverageDeduplicatesDocumentsByPath() {
        let coverage = NotesController.meetingFamilyKnowledgeBaseCoverage(from: [
            KBContextPack(
                matchedText: "Merchant ops decisions",
                relativePath: "ops/payment-ops.md",
                documentTitle: "Payment Ops",
                score: 0.91
            ),
            KBContextPack(
                matchedText: "Older chunk",
                relativePath: "ops/payment-ops.md",
                documentTitle: "Payment Ops",
                score: 0.44
            ),
            KBContextPack(
                matchedText: "Platform notes",
                relativePath: "platform/weekly.md",
                documentTitle: "Weekly Platform",
                score: 0.72
            ),
        ])

        XCTAssertEqual(coverage?.documentCount, 2)
        XCTAssertEqual(coverage?.topDocuments.map(\.title), ["Payment Ops", "Weekly Platform"])
    }

    func testMeetingFamilyKnowledgeBaseCoverageFallsBackToDocumentTitleWithoutPath() {
        let coverage = NotesController.meetingFamilyKnowledgeBaseCoverage(from: [
            KBContextPack(
                matchedText: "Roadmap details",
                relativePath: "",
                documentTitle: "Roadmap",
                score: 0.81
            )
        ])

        XCTAssertEqual(coverage?.documentCount, 1)
        XCTAssertEqual(coverage?.topDocuments.first?.title, "Roadmap")
    }

    func testNormalizedNotesMarkdownPrependsFallbackHeadingWhenMissing() {
        let markdown = NotesController.normalizedNotesMarkdown(
            "## Summary\nHello",
            title: "Standup",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(markdown.hasPrefix("# Meeting Notes: Standup\n\n## Summary\nHello"))
    }

    func testNormalizedNotesMarkdownFallsBackToDateForMissingTitle() {
        let markdown = NotesController.normalizedNotesMarkdown(
            "## Summary\nHello",
            title: "",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(markdown.hasPrefix("# Meeting Notes: "))
        XCTAssertFalse(markdown.hasPrefix("# Meeting Notes: \n"))
    }

    func testNormalizedNotesMarkdownPreservesExistingHeading() {
        let markdown = NotesController.normalizedNotesMarkdown(
            "# Test Notes\n\n## Summary\nHello",
            title: "Standup",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(markdown, "# Test Notes\n\n## Summary\nHello")
    }

    func testOriginalTranscriptToggle() async {
        let (root, _) = makeTempDirs()
        let (controller, _) = makeController(root: root)

        XCTAssertFalse(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertTrue(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertFalse(controller.state.showingOriginal)
    }

    func testGenerateNotesUpdatesGeneratingFlags() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_flags"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertFalse(controller.isGenerating(sessionID: sessionID))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        
        // Synchronous start
        XCTAssertTrue(controller.isAnyGenerationInProgress)
        XCTAssertTrue(controller.isGenerating(sessionID: sessionID))
        XCTAssertEqual(controller.generatingSessionName, "Test Meeting")

        // Wait for finish
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertFalse(controller.isGenerating(sessionID: sessionID))
    }

    func testGenerateNotesUpdatesFreshlyGeneratedWhenSwitchedAway() async {
        let (root, notes) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let settings = makeSettings(notesDirectory: notes)
        let sessionID = "session_test_fresh_switch"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        // Start generation
        controller.generateNotes(sessionID: sessionID, settings: settings)

        // Switch to a different session (or nil) immediately
        controller.selectSession(nil)

        // Wait for generation to finish in the background
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(controller.isAnyGenerationInProgress)
        XCTAssertTrue(controller.state.freshlyGeneratedSessionIDs.contains(sessionID))
        XCTAssertNil(controller.state.loadedNotes, "Should not update loadedNotes for the current unselected view")

        // Switch back to it
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(controller.state.freshlyGeneratedSessionIDs.contains(sessionID), "Should clear the fresh badge when selected")
        XCTAssertNotNil(controller.state.loadedNotes, "Should load the generated notes")
    }

    func testCancelGenerationDoesNotPersistPartialNotes() async {
        let (root, notes) = makeTempDirs()
        let settings = makeSettings(notesDirectory: notes)
        let notesEngine = NotesEngine(
            mode: .scriptedDelayed(
                markdown: "# Partial Notes\n\n## Summary\nThis should not persist.",
                delay: .milliseconds(300)
            )
        )
        let (controller, coordinator) = makeController(root: root, settings: settings, notesEngine: notesEngine)
        let sessionID = "session_test_cancel_generation"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await controller.loadHistory()
        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))

        controller.generateNotes(sessionID: sessionID, settings: settings)
        try? await Task.sleep(for: .milliseconds(50))
        controller.cancelGeneration()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(controller.state.notesGenerationStatus, .idle)
        XCTAssertTrue(controller.state.streamingMarkdown.isEmpty)
        XCTAssertNil(controller.state.loadedNotes)

        let data = await coordinator.sessionRepository.loadSessionData(sessionID: sessionID)
        XCTAssertNil(data.notes)
    }

    func testAllTagsHidesGranolaImportMetadataTags() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)

        await seedSession(coordinator: coordinator, sessionID: "session_local", title: "Local")
        await coordinator.sessionRepository.updateSessionTags(
            sessionID: "session_local",
            tags: ["follow-up"]
        )

        await seedSession(coordinator: coordinator, sessionID: "session_granola", title: "Imported")
        await coordinator.sessionRepository.updateSessionSource(
            sessionID: "session_granola",
            source: "granola",
            tags: ["granola:not_123"]
        )
        await coordinator.sessionRepository.updateSessionTags(
            sessionID: "session_granola",
            tags: ["customer"]
        )

        await controller.loadHistory()

        let tags = await controller.allTags()

        XCTAssertEqual(tags, ["customer", "follow-up"])
        XCTAssertFalse(tags.contains(where: { $0.hasPrefix("granola:") }))
    }

    func testSessionSourceGroupsKeepGranolaSeparateFromOpenOats() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        await seedSession(
            coordinator: coordinator,
            sessionID: "session_local",
            title: "Local",
            startedAt: base
        )

        await seedSession(
            coordinator: coordinator,
            sessionID: "session_granola",
            title: "Imported",
            startedAt: base.addingTimeInterval(300)
        )
        await coordinator.sessionRepository.updateSessionSource(
            sessionID: "session_granola",
            source: "granola",
            tags: ["granola:not_456"]
        )

        await controller.loadHistory()

        let groups = controller.sessionSourceGroups

        XCTAssertEqual(groups.map(\.title), ["Granola", "OpenOats"])
        XCTAssertEqual(groups.first?.sessions.map(\.id), ["session_granola"])
        XCTAssertEqual(groups.last?.sessions.map(\.id), ["session_local"])
        XCTAssertTrue(controller.showsSourceSections)
    }
}
