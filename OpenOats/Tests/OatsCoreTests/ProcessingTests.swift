import Foundation
import OatsCore
import Testing

/// Seam 1: Meeting folder → Processing → Meeting file.
@Suite final class ProcessingTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    @Test func mergesTracksIntoYouAndThemByTime() async throws {
        let folder = try ws.recordedMeeting()
        let status = try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))

        #expect(status.state == .done)
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("""
        [00:00:00] **You:** Hi there, thanks for joining.

        [00:00:03] **Them:** Happy to be here.

        [00:00:06] **You:** Let's start with the roadmap.
        """))
        #expect(file.contains("participants:\n  - You\n  - Them\n"))
        #expect(file.contains("engine: fake-transcription"))
        #expect(file.hasPrefix("---\nschema: openoats/v1\n"))
    }

    @Test func joinsCloseSameSpeakerSegmentsIntoOneTurn() async throws {
        let folder = try ws.recordedMeeting()
        let transcription = FakeTranscription(segments: [.mic: [seg(0, 2, "First part."), seg(2.5, 4, "Second part.")]])
        try await Processing.run(folder, options: ws.options(transcription))
        #expect(try ws.onlyMeetingFile().contains("[00:00:00] **You:** First part. Second part.\n"))
    }

    @Test func dropsMicTrackEchoesOfThemWhenOnSpeakers() async throws {
        // Synthetic speakers-not-headphones pair: the mic hears Them slightly late and garbled.
        let folder = try ws.recordedMeeting()
        let transcription = FakeTranscription(segments: [
            .system: [seg(10, 14, "We shipped the Almarai integration last week."), seg(20, 22, "Any questions?")],
            .mic: [
                seg(10.4, 14.3, "we shipped the al marai integration last week"),
                seg(11, 12, "Sorry, go on."),
                seg(15, 17, "Great, what about Talabat?"),
                seg(20.3, 22.2, "any questions"),
            ],
        ])
        try await Processing.run(folder, options: ws.options(transcription))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("[00:00:10] **Them:** We shipped the Almarai integration last week."))
        #expect(!file.contains("**You:** we shipped"))
        #expect(!file.contains("**You:** any questions"))
        #expect(file.contains("[00:00:11] **You:** Sorry, go on."))
        #expect(file.contains("[00:00:15] **You:** Great, what about Talabat?"))
    }

    @Test func dropsEchoesTheMicTrackMisheard() async throws {
        let folder = try ws.recordedMeeting()
        let transcription = FakeTranscription(segments: [
            .system: [seg(30, 31, "Choco pic."), seg(40, 43, "It's still intuitive too, man.")],
            .mic: [seg(30.2, 31.2, "Choco pig."), seg(40.3, 43.2, "It's still in tuitive two man."), seg(44, 45, "Totally, man.")],
        ])
        try await Processing.run(folder, options: ws.options(transcription))

        let file = try ws.onlyMeetingFile()
        #expect(!file.contains("**You:** Choco"))
        #expect(!file.contains("**You:** It's still"))
        #expect(file.contains("[00:00:44] **You:** Totally, man."))
    }

    @Test func skipsNotesWithoutNotesBackendAndTitlesByDateAndTime() async throws {
        let folder = try ws.recordedMeeting()
        let status = try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))

        #expect(status.state == .done)
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-meeting.md"])
        let title = Workspace.start.formatted(date: .abbreviated, time: .shortened)
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("title: \"\(title)\"\n"))
        #expect(file.contains("\n# \(title)\n\n## Transcript\n"))
        #expect(!file.contains("## Summary"))
    }

    @Test func writesNotesAndTitleFromNotesBackend() async throws {
        let folder = try ws.recordedMeeting()
        let notes = FakeNotes(reply: "Title: Weekly Sync\n\n## Summary\n\nWe agreed on the roadmap.")
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks), notes: notes))

        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-weekly-sync.md"])
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("title: \"Weekly Sync\""))
        #expect(file.contains("# Weekly Sync\n\n## Summary\n\nWe agreed on the roadmap.\n\n## Transcript\n"))
    }

    @Test func notesFailureStillWritesTranscriptThenRetryAddsNotes() async throws {
        let folder = try ws.recordedMeeting()
        let transcription = FakeTranscription(segments: basicTracks)
        let failed = try await Processing.run(folder, options: ws.options(transcription, notes: FakeNotes(reply: nil)))

        #expect(failed.state == .needsAttention)
        #expect(failed.lastError?.contains("Needs attention: the Notes weren't written. service unavailable") == true)
        #expect(try ws.onlyMeetingFile().contains("**Them:** Happy to be here."))

        let retried = try await Processing.run(folder, options: ws.options(transcription, notes: FakeNotes(reply: "Title: Retro\n## Summary\nDone.")))
        #expect(retried.state == .done)
        #expect(retried.lastError == nil)
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-retro.md"])
        #expect(try ws.onlyMeetingFile().contains("## Summary\nDone."))
    }

    @Test func transcriptionFailureNeedsAttentionAndRetryResumesFromCheckpoint() async throws {
        let folder = try ws.recordedMeeting()
        let first = FakeTranscription(segments: [.mic: [seg(0, 1, "Checkpointed mic text.")]], failing: [.system])
        let failed = try await Processing.run(folder, options: ws.options(first))

        #expect(failed.state == .needsAttention)
        #expect(failed.lastError == "service unavailable")
        #expect(ws.meetingFiles.isEmpty)
        #expect(ws.files(in: folder).isSuperset(of: ["mic.pcm", "system.pcm"]))

        let second = FakeTranscription(segments: [.mic: [seg(0, 1, "Re-transcribed.")], .system: [seg(2, 3, "Now it works.")]])
        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(second) }
        try await queue.enqueue(folder) // Retry
        await queue.waitUntilIdle()

        #expect(try folder.readStatus().state == .done)
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("**You:** Checkpointed mic text."))
        #expect(!file.contains("Re-transcribed."))
        #expect(file.contains("**Them:** Now it works."))
    }

    @Test func resumesMeetingsLeftInProcessingOnLaunch() async throws {
        let pending = try ws.recordedMeeting()
        let finished = try ws.recordedMeeting(start: Workspace.start.addingTimeInterval(3600))
        try finished.updateStatus { $0.state = .done }

        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(FakeTranscription(segments: basicTracks)) }
        await queue.resumePending()
        await queue.waitUntilIdle()

        #expect(try pending.readStatus().state == .done)
        #expect(ws.meetingFiles.count == 1)
        #expect(ws.files(in: finished).contains("mic.pcm"))
    }

    @Test func marksInterruptedMeetings() async throws {
        let folder = try ws.recordedMeeting(interrupted: true)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))
        #expect(try ws.onlyMeetingFile().contains("\ninterrupted: true\n"))

        let other = Workspace()
        try await Processing.run(try other.recordedMeeting(), options: other.options(FakeTranscription(segments: basicTracks)))
        #expect(try !other.onlyMeetingFile().contains("interrupted"))
        try? FileManager.default.removeItem(at: other.root)
    }

    @Test func reprocessReplacesUneditedMeetingFile() async throws {
        let folder = try ws.recordedMeeting()
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))

        try Processing.prepareReprocess(folder)
        let better = FakeTranscription(name: "better-transcription", segments: [.mic: [seg(0, 1, "Better words.")]])
        try await Processing.run(folder, options: ws.options(better))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("**You:** Better words."))
        #expect(file.contains("engine: better-transcription"))
    }

    @Test func reprocessNeverOverwritesAnEditedMeetingFile() async throws {
        let folder = try ws.recordedMeeting()
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))
        let original = ws.meetingFiles[0]
        try (try String(contentsOf: original, encoding: .utf8) + "\nMy own note.\n").write(to: original, atomically: true, encoding: .utf8)

        try Processing.prepareReprocess(folder)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: [.mic: [seg(0, 1, "Again.")]])))

        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-meeting-2.md", "\(ws.datePrefix)-meeting.md"])
        #expect(try String(contentsOf: original, encoding: .utf8).contains("My own note."))
        #expect(try String(contentsOf: ws.meetingFiles[0], encoding: .utf8).contains("**You:** Again."))
    }

    @Test func reprocessOfAnEditedFileWritesASiblingEvenWhenTheTitleChanges() async throws {
        let folder = try ws.recordedMeeting()
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))
        func edit(_ url: URL) throws { try (try String(contentsOf: url, encoding: .utf8) + "\nMine.\n").write(to: url, atomically: true, encoding: .utf8) }
        try edit(ws.meetingFiles[0])

        try Processing.prepareReprocess(folder)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks), notes: FakeNotes(reply: "Title: Other\n\nx")))
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-meeting-2.md", "\(ws.datePrefix)-meeting.md"])
        #expect(try String(contentsOf: ws.meetingFiles[0], encoding: .utf8).contains("title: \"Other\""))

        try edit(ws.meetingFiles[0])
        try Processing.prepareReprocess(folder)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["meeting-2", "meeting-3", "meeting"].map { "\(ws.datePrefix)-\($0).md" })
    }

    @Test func compressesTracksToM4AAfterWritingMeetingFile() async throws {
        let folder = try ws.recordedMeeting(seconds: 3)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))

        let files = ws.files(in: folder)
        #expect(files.isSuperset(of: ["mic.m4a", "system.m4a"]))
        #expect(!files.contains("mic.pcm") && !files.contains("system.pcm"))
        #expect(abs(TrackAudio.duration(of: folder.url.appendingPathComponent("mic.m4a")) - 3) < 0.2)
        #expect(ws.meetingFiles.count == 1)
    }

    @Test func deletesTracksWhenAudioIsNotKept() async throws {
        let folder = try ws.recordedMeeting()
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks), keepAudio: false))

        #expect(ws.files(in: folder).allSatisfy { $0.hasSuffix(".json") })
        #expect(ws.meetingFiles.count == 1)
    }

    @Test func singleMixedImportUsesNeutralSpeakerLabel() async throws {
        let audio = ws.root.appendingPathComponent("import.pcm")
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.pcm(seconds: 1).write(to: audio)
        let folder = try ws.store.importAudio([audio], startedAt: Workspace.start)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: [.mixed: [seg(1, 2, "Hello everyone.")]])))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("\n[00:00:01] **Speaker:** Hello everyone.\n"))
        #expect(file.contains("participants:\n  - Speaker\n"))
        #expect(!file.contains("**You:**") && !file.contains("**Them:**"))
        #expect(ws.files(in: folder).contains("mixed.m4a"))
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func singleMixedImportKeepsEachSegmentOnItsOwnLine() async throws {
        let audio = ws.root.appendingPathComponent("import.pcm")
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.pcm(seconds: 1).write(to: audio)
        let folder = try ws.store.importAudio([audio], startedAt: Workspace.start)
        let transcription = FakeTranscription(segments: [.mixed: [seg(0, 1, "How would you order?"), seg(1.5, 3, "Through the app.")]])
        try await Processing.run(folder, options: ws.options(transcription))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("[00:00:00] **Speaker:** How would you order?\n\n[00:00:01] **Speaker:** Through the app."))
    }

    @Test func singleMixedImportKeepsLabelsFromDiarizingBackend() async throws {
        let audio = ws.root.appendingPathComponent("import.pcm")
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.pcm(seconds: 1).write(to: audio)
        let folder = try ws.store.importAudio([audio], startedAt: Workspace.start)
        let transcription = FakeTranscription(segments: [.mixed: [seg(0, 1, "Hi.", "Speaker 1"), seg(1, 2, "Hello.", "Speaker 2")]], separatesSpeakers: true)
        try await Processing.run(folder, options: ws.options(transcription))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("[00:00:00] **Speaker 1:** Hi.\n\n[00:00:01] **Speaker 2:** Hello."))
    }

    @Test func queueProcessesOneMeetingAtATime() async throws {
        let a = try ws.recordedMeeting()
        let b = try ws.recordedMeeting(start: Workspace.start.addingTimeInterval(7200))
        // While the backend works on one Meeting, the state of the other.
        let seen = Log<(String, MeetingStatus.State?)>()
        let transcription = FakeTranscription(segments: basicTracks, during: { audio in
            let other = audio.deletingLastPathComponent().lastPathComponent == a.id ? b : a
            seen.add((other.id, try? other.readStatus().state))
        })
        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(transcription) }
        try await queue.enqueue(a)
        try await queue.enqueue(b)
        await queue.waitUntilIdle()

        #expect(ws.meetingFiles.count == 2)
        #expect(try a.readStatus().state == .done && b.readStatus().state == .done)
        #expect(seen.items.count == 4)
        #expect(seen.items.filter { $0.0 == b.id }.allSatisfy { $0.1 == .processing }) // b waits while a runs
        #expect(seen.items.filter { $0.0 == a.id }.allSatisfy { $0.1 == .done }) // a is done before b starts
    }

    @Test func statusChangesMadeDuringProcessingAreKept() async throws {
        let folder = try ws.recordedMeeting()
        let transcription = FakeTranscription(segments: basicTracks, during: { _ in
            _ = try? folder.updateStatus { $0.title = "Renamed meanwhile" }
        })
        try await Processing.run(folder, options: ws.options(transcription))

        #expect(try folder.readStatus().title == "Renamed meanwhile")
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-renamed-meanwhile.md"])
    }

    @Test func aMeetingIsNeverProcessedTwiceAtOnce() async throws {
        let folder = try ws.recordedMeeting()
        let second = Log<String>()
        let transcription = FakeTranscription(segments: basicTracks, during: { [ws] _ in
            do {
                try await Processing.run(folder, options: ws.options(FakeTranscription(segments: [.mic: [seg(0, 1, "Twice.")]])))
                second.add("ran")
            } catch { second.add(error.localizedDescription) }
        })
        try await Processing.run(folder, options: ws.options(transcription))

        #expect(second.items == Array(repeating: "This Meeting is being recorded or processed by another OpenOats.", count: 2))
        #expect(try folder.readStatus().state == .done)
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("**Them:** Happy to be here.") && !file.contains("Twice."))
    }

    @Test func aMeetingDeletedDuringProcessingFailsQuietlyAndTheQueueGoesOn() async throws {
        let gone = try ws.recordedMeeting()
        let next = try ws.recordedMeeting(start: Workspace.start.addingTimeInterval(7200))
        let transcription = FakeTranscription(segments: basicTracks, during: { audio in
            if audio.deletingLastPathComponent().lastPathComponent == gone.id { try? FileManager.default.removeItem(at: gone.url) }
        })
        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(transcription) }
        try await queue.enqueue(gone)
        try await queue.enqueue(next)
        await queue.waitUntilIdle()

        #expect(!FileManager.default.fileExists(atPath: gone.url.path))
        #expect(try next.readStatus().state == .done)
        #expect(ws.meetingFiles.count == 1)
    }

    @Test func aMeetingWithNoSpeechStillNamesAParticipant() async throws {
        try await Processing.run(try ws.recordedMeeting(), options: ws.options(FakeTranscription(segments: [:])))
        #expect(try ws.onlyMeetingFile().contains("participants:\n  - You\n"))

        let other = Workspace()
        defer { try? FileManager.default.removeItem(at: other.root) }
        let audio = other.root.appendingPathComponent("import.pcm")
        try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
        try other.pcm(seconds: 1).write(to: audio)
        try await Processing.run(try other.store.importAudio([audio]), options: other.options(FakeTranscription(segments: [:])))
        #expect(try other.onlyMeetingFile().contains("participants:\n  - Speaker\n"))
    }
}
