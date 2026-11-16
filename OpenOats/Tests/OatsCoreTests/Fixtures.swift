import Foundation
import OatsCore

struct FakeError: LocalizedError {
    var errorDescription: String? { "service unavailable" }
}

/// Returns set segments per track (`mic`, `system`, `mixed`); tracks in `failing` throw.
struct FakeTranscription: TranscriptionBackend {
    var name = "fake-asr"
    var segments: [String: [TimedSegment]]
    var failing: Set<String> = []
    var separatesSpeakers = false
    var calls: CallLog? = nil

    func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        let role = audio.deletingPathExtension().lastPathComponent
        await calls?.begin()
        try? await Task.sleep(for: .milliseconds(20))
        await calls?.end()
        if failing.contains(role) { throw FakeError() }
        return segments[role] ?? []
    }
}

actor CallLog {
    private(set) var active = 0
    private(set) var maxActive = 0
    func begin() { active += 1; maxActive = max(maxActive, active) }
    func end() { active -= 1 }
}

struct FakeNotes: NotesBackend {
    var name = "fake-notes"
    var contextTokens = 100_000
    var reply: String?

    func complete(system: String, user: String) async throws -> String {
        guard let reply else { throw FakeError() }
        return reply
    }
}

func seg(_ start: Double, _ end: Double, _ text: String, _ speaker: String? = nil) -> TimedSegment {
    TimedSegment(start: start, end: end, text: text, speaker: speaker)
}

/// A temporary Meeting store and notes folder.
struct Workspace {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oats-tests-\(UUID().uuidString)")
    var store: MeetingStore { MeetingStore(root: root.appendingPathComponent("Meetings")) }
    var notesFolder: URL { root.appendingPathComponent("Notes") }
    static let start = Date(timeIntervalSince1970: 1_763_276_520) // 2025-11-16 07:02 UTC

    /// A Meeting folder as the Recorder leaves it after Stop: two PCM tracks, state `processing`.
    func recordedMeeting(seconds: Double = 2, interrupted: Bool = false, start: Date = Workspace.start) throws -> MeetingFolder {
        let folder = try store.create(startedAt: start, language: "en")
        try pcm(seconds: seconds).write(to: folder.micTrackURL)
        try pcm(seconds: seconds).write(to: folder.systemTrackURL)
        try folder.updateStatus {
            $0.state = .processing
            $0.interrupted = interrupted
        }
        return folder
    }

    func pcm(seconds: Double) -> Data {
        var data = Data()
        for i in 0..<Int(seconds * 16_000) {
            var sample = Int16(sin(Double(i) * 0.1) * 8000).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    func options(_ asr: FakeTranscription, notes: FakeNotes? = nil, keepAudio: Bool = true) -> ProcessingOptions {
        ProcessingOptions(transcription: asr, notes: notes, notesFolder: notesFolder, keepAudio: keepAudio)
    }

    var meetingFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func onlyMeetingFile() throws -> String {
        guard meetingFiles.count == 1 else { throw FakeError() }
        return try String(contentsOf: meetingFiles[0], encoding: .utf8)
    }

    func files(in folder: MeetingFolder) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? [])
    }

    var datePrefix: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Workspace.start)
    }
}

let basicTracks: [String: [TimedSegment]] = [
    "mic": [seg(0, 2, "Hi there, thanks for joining."), seg(6, 8, "Let's start with the roadmap.")],
    "system": [seg(3, 5, "Happy to be here.")],
]
