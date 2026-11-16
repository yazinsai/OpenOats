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
        #expect(file.contains("engine: fake-asr"))
        #expect(file.hasPrefix("---\nschema: openoats/v1\n"))
    }

    @Test func joinsCloseSameSpeakerSegmentsIntoOneTurn() async throws {
        let folder = try ws.recordedMeeting()
        let asr = FakeTranscription(segments: ["mic": [seg(0, 2, "First part."), seg(2.5, 4, "Second part.")]])
        try await Processing.run(folder, options: ws.options(asr))
        #expect(try ws.onlyMeetingFile().contains("[00:00:00] **You:** First part. Second part.\n"))
    }

    @Test func dropsMicTrackEchoesOfThemWhenOnSpeakers() async throws {
        // Synthetic speakers-not-headphones pair: the mic hears Them slightly late and garbled.
        let folder = try ws.recordedMeeting()
        let asr = FakeTranscription(segments: [
            "system": [seg(10, 14, "We shipped the Almarai integration last week."), seg(20, 22, "Any questions?")],
            "mic": [
                seg(10.4, 14.3, "we shipped the al marai integration last week"),
                seg(11, 12, "Sorry, go on."),
                seg(15, 17, "Great, what about Talabat?"),
                seg(20.3, 22.2, "any questions"),
            ],
        ])
        try await Processing.run(folder, options: ws.options(asr))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("[00:00:10] **Them:** We shipped the Almarai integration last week."))
        #expect(!file.contains("**You:** we shipped"))
        #expect(!file.contains("**You:** any questions"))
        #expect(file.contains("[00:00:11] **You:** Sorry, go on."))
        #expect(file.contains("[00:00:15] **You:** Great, what about Talabat?"))
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
        let asr = FakeTranscription(segments: basicTracks)
        let failed = try await Processing.run(folder, options: ws.options(asr, notes: FakeNotes(reply: nil)))

        #expect(failed.state == .needsAttention)
        #expect(failed.lastError?.contains("Notes failed: service unavailable") == true)
        #expect(try ws.onlyMeetingFile().contains("**Them:** Happy to be here."))

        let retried = try await Processing.run(folder, options: ws.options(asr, notes: FakeNotes(reply: "Title: Retro\n## Summary\nDone.")))
        #expect(retried.state == .done)
        #expect(retried.lastError == nil)
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-retro.md"])
        #expect(try ws.onlyMeetingFile().contains("## Summary\nDone."))
    }

    @Test func transcriptionFailureNeedsAttentionAndRetryResumesFromCheckpoint() async throws {
        let folder = try ws.recordedMeeting()
        let first = FakeTranscription(segments: ["mic": [seg(0, 1, "Checkpointed mic text.")]], failing: ["system"])
        let failed = try await Processing.run(folder, options: ws.options(first))

        #expect(failed.state == .needsAttention)
        #expect(failed.lastError == "service unavailable")
        #expect(ws.meetingFiles.isEmpty)
        #expect(ws.files(in: folder).isSuperset(of: ["mic.pcm", "system.pcm"]))

        let second = FakeTranscription(segments: ["mic": [seg(0, 1, "Re-transcribed.")], "system": [seg(2, 3, "Now it works.")]])
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
        let better = FakeTranscription(name: "better-asr", segments: ["mic": [seg(0, 1, "Better words.")]])
        try await Processing.run(folder, options: ws.options(better))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("**You:** Better words."))
        #expect(file.contains("engine: better-asr"))
    }

    @Test func reprocessNeverOverwritesAnEditedMeetingFile() async throws {
        let folder = try ws.recordedMeeting()
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: basicTracks)))
        let original = ws.meetingFiles[0]
        try (try String(contentsOf: original, encoding: .utf8) + "\nMy own note.\n").write(to: original, atomically: true, encoding: .utf8)

        try Processing.prepareReprocess(folder)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: ["mic": [seg(0, 1, "Again.")]])))

        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-meeting-2.md", "\(ws.datePrefix)-meeting.md"])
        #expect(try String(contentsOf: original, encoding: .utf8).contains("My own note."))
        #expect(try String(contentsOf: ws.meetingFiles[0], encoding: .utf8).contains("**You:** Again."))
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

    @Test func singleMixedImportHasNoYouThemLabels() async throws {
        let audio = ws.root.appendingPathComponent("call.pcm")
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.pcm(seconds: 1).write(to: audio)
        let folder = try ws.store.importAudio([audio], startedAt: Workspace.start)
        try await Processing.run(folder, options: ws.options(FakeTranscription(segments: ["mixed": [seg(1, 2, "Hello everyone.")]])))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("\n[00:00:01] Hello everyone.\n"))
        #expect(!file.contains("**You:**") && !file.contains("**Them:**"))
        #expect(ws.files(in: folder).contains("mixed.m4a"))
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func singleMixedImportKeepsLabelsFromDiarizingBackend() async throws {
        let audio = ws.root.appendingPathComponent("call.pcm")
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        try ws.pcm(seconds: 1).write(to: audio)
        let folder = try ws.store.importAudio([audio], startedAt: Workspace.start)
        let asr = FakeTranscription(segments: ["mixed": [seg(0, 1, "Hi.", "Speaker 1"), seg(1, 2, "Hello.", "Speaker 2")]], separatesSpeakers: true)
        try await Processing.run(folder, options: ws.options(asr))

        let file = try ws.onlyMeetingFile()
        #expect(file.contains("[00:00:00] **Speaker 1:** Hi.\n\n[00:00:01] **Speaker 2:** Hello."))
    }

    @Test func queueProcessesOneMeetingAtATime() async throws {
        let calls = CallLog()
        let a = try ws.recordedMeeting()
        let b = try ws.recordedMeeting(start: Workspace.start.addingTimeInterval(7200))
        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(FakeTranscription(segments: basicTracks, calls: calls)) }
        try await queue.enqueue(a)
        try await queue.enqueue(b)
        await queue.waitUntilIdle()

        #expect(ws.meetingFiles.count == 2)
        #expect(await calls.maxActive == 1)
        #expect(await queue.queued.isEmpty)
    }
}
