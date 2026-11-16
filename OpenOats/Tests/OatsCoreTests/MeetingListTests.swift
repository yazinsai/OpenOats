import Foundation
import OatsCore
import Testing

/// Seam 1: the Meeting store operations the window uses (list, rename, delete, locate audio).
@Suite final class MeetingListTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    func run(_ folder: MeetingFolder, _ asr: FakeTranscription = FakeTranscription(segments: basicTracks),
             notes: FakeNotes? = nil, keepAudio: Bool = true) async throws {
        try await Processing.run(folder, options: ws.options(asr, notes: notes, keepAudio: keepAudio))
    }

    func writeNote(_ name: String, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: ws.notesFolder, withIntermediateDirectories: true)
        let url = ws.notesFolder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    let legacy = """
    ---
    schema: openoats/v1
    title: "Closing \\"and\\" sign-off"
    date: 2026-04-01T13:02:10+03:00
    duration: 23
    participants:
      - You
    x_openoats_session: "session_2026-04-01_13-02-10"
    ---
    # Closing "and" sign-off

    ## Transcript

    [00:00:00] **You:** Bye.
    """

    @Test func listsMeetingsNewestFirstWithTheirState() async throws {
        let done = try ws.recordedMeeting(start: Workspace.start)
        try await run(done, notes: FakeNotes(reply: "Title: Roadmap review\n\n## Summary\nShipped."))
        let failed = try ws.recordedMeeting(start: Workspace.start + 3600)
        try await run(failed, FakeTranscription(segments: basicTracks, failing: ["mic"]))
        let interrupted = try ws.recordedMeeting(interrupted: true, start: Workspace.start + 7200)
        try await run(interrupted)
        let queued = try ws.recordedMeeting(start: Workspace.start + 10800)
        let recording = try ws.store.create(startedAt: Workspace.start + 14400)

        let entries = ws.store.entries(notesFolder: ws.notesFolder)
        #expect(entries.map(\.id) == [recording.id, queued.id, interrupted.id, failed.id, done.id])
        #expect(entries.map(\.state) == [.recording, .processing, .interrupted, .needsAttention("service unavailable"), .done])
        #expect(entries[4].title == "Roadmap review")
        #expect(entries[4].meetingFile?.lastPathComponent == "\(ws.datePrefix)-roadmap-review.md")
        #expect(entries[4].date == Workspace.start)
        #expect(entries[1].title == (Workspace.start + 10800).formatted(date: .abbreviated, time: .shortened))
        #expect(entries[1].meetingFile == nil)
    }

    @Test func listsMeetingFilesCarriedOverFrom1xWithoutAFolder() async throws {
        let folder = try ws.recordedMeeting()
        try await run(folder)
        _ = try writeNote("2026-04-01-1302-closing-and-sign-off.md", legacy)
        let bare = try writeNote("2026-03-19-2128-meeting.md", "Just text, no frontmatter.\n")
        _ = try writeNote("todo.md", "- not a Meeting\n")

        let entries = ws.store.entries(notesFolder: ws.notesFolder)
        #expect(entries.count == 3)
        let old = try #require(entries.first { $0.title == "Closing \"and\" sign-off" })
        #expect(old.folder == nil && old.state == .done)
        #expect(old.date == ISO8601DateFormatter().date(from: "2026-04-01T10:02:10Z"))
        #expect(old.duration == 1380, "\(String(describing: old.duration))")
        let plain = try #require(entries.first { $0.meetingFile?.lastPathComponent == bare.lastPathComponent })
        #expect(plain.title == "2026-03-19-2128-meeting")
        #expect(entries.filter { $0.folder?.id == folder.id }.count == 1)
    }

    @Test func renameRenamesTheFileAndKeepsItRecognisedForReprocess() async throws {
        let folder = try ws.recordedMeeting()
        try await run(folder)
        let entry = try #require(ws.store.entries(notesFolder: ws.notesFolder).first)

        try ws.store.rename(entry, to: "Budget: Q3 / Q4")
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-budget-q3-q4.md"])
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("title: \"Budget: Q3 / Q4\"\n"))
        #expect(file.contains("\n# Budget: Q3 / Q4\n"))
        #expect(ws.store.entries(notesFolder: ws.notesFolder).first?.title == "Budget: Q3 / Q4")

        try Processing.prepareReprocess(folder)
        try await run(folder, FakeTranscription(segments: ["mic": [seg(0, 1, "Again.")]]), notes: FakeNotes(reply: "Title: Other\n\nx"))
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-budget-q3-q4.md"])
        #expect(try ws.onlyMeetingFile().contains("**You:** Again."))
    }

    @Test func renameOf1xFileKeepsItsDatePrefix() throws {
        _ = try writeNote("2026-04-01-1302-closing-and-sign-off.md", legacy)
        let entry = try #require(ws.store.entries(notesFolder: ws.notesFolder).first)

        try ws.store.rename(entry, to: "Wrap-up")
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["2026-04-01-1302-wrap-up.md"])
        let file = try ws.onlyMeetingFile()
        #expect(file.contains("title: \"Wrap-up\"\n") && file.contains("\n# Wrap-up\n") && file.contains("**You:** Bye."))
    }

    @Test func renameDoesNotOverwriteAnotherMeetingFile() async throws {
        let first = try ws.recordedMeeting()
        try await run(first, notes: FakeNotes(reply: "Title: Sync\n\nx"))
        let second = try ws.recordedMeeting()
        try await run(second)
        let entry = try #require(ws.store.entries(notesFolder: ws.notesFolder).first { $0.folder?.id == second.id })

        try ws.store.rename(entry, to: "Sync")
        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-sync-2.md", "\(ws.datePrefix)-sync.md"])
    }

    @Test func deleteRemovesMeetingFileAndFolder() async throws {
        let folder = try ws.recordedMeeting()
        try await run(folder)
        _ = try writeNote("2026-04-01-1302-closing-and-sign-off.md", legacy)

        for entry in ws.store.entries(notesFolder: ws.notesFolder) { try ws.store.delete(entry) }
        #expect(ws.meetingFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
        #expect(ws.store.entries(notesFolder: ws.notesFolder).isEmpty)
    }

    @Test func locatesKeptAudio() async throws {
        let kept = try ws.recordedMeeting()
        try await run(kept)
        let dropped = try ws.recordedMeeting(start: Workspace.start + 60)
        try await run(dropped, keepAudio: false)
        let input = ws.root.appendingPathComponent("call.wav")
        try ws.pcm(seconds: 1).write(to: input)
        let imported = try ws.store.importAudio([input], startedAt: Workspace.start + 120)

        let entries = ws.store.entries(notesFolder: ws.notesFolder)
        let audio = { (f: MeetingFolder) in entries.first { $0.folder?.id == f.id }?.audioFiles.map(\.lastPathComponent).sorted() }
        #expect(audio(kept) == ["mic.m4a", "system.m4a"])
        #expect(audio(dropped) == [])
        #expect(audio(imported) == ["mixed.wav"])
    }
}
