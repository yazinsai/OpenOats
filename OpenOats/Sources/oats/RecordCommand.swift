import Foundation
import OatsCore

/// Meetings root; `OATS_MEETINGS_DIR` overrides it (tests).
let meetingStore = ProcessInfo.processInfo.environment["OATS_MEETINGS_DIR"].map { MeetingStore(root: URL(fileURLWithPath: $0)) }
    ?? MeetingStore()

/// `oats record [--fake-source] [--seconds N]`: records until N seconds or Ctrl-C, then processes. Prints the Meeting id
/// once recording, then the Meeting file path(s).
func recordCommand(source: any CaptureSource, seconds: Double?, options: ProcessingOptions) async throws {
    let stopRequested = Flag()
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT)
    sigint.setEventHandler { stopRequested.set() }
    sigint.resume()
    let recorder = try Recorder.start(store: meetingStore, source: source, language: nil, onEvent: { event in
        switch event {
        case let .lowDisk(free): log("low disk space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        case let .stopped(_, reason): log(reason); stopRequested.set()
        }
    })
    print("recording \(recorder.folder.id)")
    fflush(stdout)
    let start = Date()
    while !stopRequested.isSet, seconds.map({ Date().timeIntervalSince(start) < $0 }) ?? true {
        try await Task.sleep(for: .milliseconds(50))
    }
    try recorder.stop()
    try await recoverCommand(options: options)
}

/// `oats recover`: what the app does on launch. Closes Interrupted meetings, then runs every queued Meeting.
func recoverCommand(options: ProcessingOptions) async throws {
    for meeting in meetingStore.recoverInterruptedMeetings() { log(meeting.message) }
    let queue = ProcessingQueue(store: meetingStore) { options }
    let before = Set(meetingStore.list().filter { (try? $0.readStatus().state) == .processing }.map(\.id))
    await queue.resumePending()
    await queue.waitUntilIdle()
    for folder in meetingStore.list() where before.contains(folder.id) {
        let status = try folder.readStatus()
        print(status.meetingFile ?? "\(folder.id): \(status.lastError ?? status.state.rawValue)")
    }
}

func log(_ message: String) { FileHandle.standardError.write(Data("oats: \(message)\n".utf8)) }

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Test Transcription backend: waits that long per track, then returns one segment giving its length
/// (worded differently per track so echo removal keeps both).
struct FakeTranscription: TranscriptionBackend {
    var name = "fake"
    var delay: Double

    func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        try await Task.sleep(for: .seconds(delay))
        let seconds = TrackAudio.duration(of: audio)
        return [TimedSegment(start: 0, end: seconds, text: (audio.lastPathComponent.hasPrefix("mic") ? "Mic track lasted " : "System audio, ") + String(format: "%.2f s", seconds))]
    }
}
