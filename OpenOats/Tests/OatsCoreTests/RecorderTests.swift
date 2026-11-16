import Foundation
import OatsCore
import Testing

/// A capture source the test drives by hand, on a hand-set clock.
final class FakeSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (CapturedAudio) -> Void)?
    var now: TimeInterval {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    private var _now: TimeInterval = 1000

    func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws { lock.withLock { self.deliver = deliver } }
    func stop() { lock.withLock { deliver = nil } }

    /// `seconds` of a constant `value` on `track`, captured `at` seconds after the Recorder started.
    func send(_ track: Track, _ value: Int16, seconds: Double, at: Double) {
        let chunk = CapturedAudio(track: track, samples: Array(repeating: value, count: Int(seconds * 16_000)), hostTime: 1000 + at)
        lock.withLock { deliver }?(chunk)
    }
}

final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64
    init(_ bytes: Int64) { _bytes = bytes }
    var bytes: Int64 {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RecorderEvent] = []
    func add(_ e: RecorderEvent) { lock.withLock { _events.append(e) } }
    var events: [RecorderEvent] { lock.withLock { _events } }
}

/// Seam 2: capture source → Recorder → Meeting folder.
@Suite final class RecorderTests: Sendable {
    let ws = Workspace()
    let source = FakeSource()
    let disk = FreeSpace(10_000_000_000)
    let log = EventLog()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    func start(flushInterval: TimeInterval = 2) throws -> Recorder {
        try Recorder.start(store: ws.store, source: source, language: "en", flushInterval: flushInterval,
                           clock: { [source] in source.now }, freeSpace: { [disk] _ in disk.bytes }, onEvent: { [log] in log.add($0) })
    }

    /// The track as Int16 samples.
    func samples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count - 1, by: 2).map { Int16(data[$0]) | Int16(data[$0 + 1]) << 8 }
    }

    func sparseFile(_ url: URL, bytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<200 where try !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func writesBothTracksAndQueuesProcessingOnStop() throws {
        let recorder = try start()
        let folder = recorder.folder
        #expect(try folder.readStatus().state == .recording)
        source.send(.mic, 100, seconds: 1, at: 0)
        source.send(.system, 200, seconds: 1, at: 0)
        source.send(.mic, 101, seconds: 0.5, at: 1)
        let stopped = try recorder.stop()

        #expect(stopped == folder)
        let mic = try samples(folder.micTrackURL), system = try samples(folder.systemTrackURL)
        #expect(mic == Array(repeating: 100, count: 16_000) + Array(repeating: 101, count: 8_000))
        #expect(system == Array(repeating: 200, count: 16_000))
        let status = try folder.readStatus()
        #expect(status.state == .processing)
        #expect(status.endedAt != nil)
        #expect(!status.interrupted)
    }

    @Test func writesSilenceOverAGapSoTracksStayAligned() throws {
        let recorder = try start()
        source.send(.system, 200, seconds: 3, at: 0)
        source.send(.mic, 100, seconds: 1, at: 0)
        // The mic delivers nothing for a second (stall, engine restart), then resumes.
        source.send(.mic, 101, seconds: 1, at: 2)
        let folder = try recorder.stop()

        let mic = try samples(folder.micTrackURL)
        #expect(mic.count == 48_000)
        #expect(mic[15_999] == 100 && mic[16_000] == 0 && mic[31_999] == 0 && mic[32_000] == 101)
        #expect(try samples(folder.systemTrackURL).count == 48_000)
    }

    @Test func staysAlignedAcrossADeviceChange() throws {
        let recorder = try start()
        source.send(.mic, 100, seconds: 2, at: 0)
        // New device: different buffer size, first buffer stamped 0.5 s before what was already written.
        source.send(.mic, 101, seconds: 1, at: 1.5)
        // Small timestamp jitter is written as is, not padded or trimmed.
        source.send(.mic, 102, seconds: 0.5, at: 2.55)
        source.send(.system, 200, seconds: 3, at: 0)
        let folder = try recorder.stop()

        let mic = try samples(folder.micTrackURL)
        #expect(mic.count == 48_000)
        #expect(mic[31_999] == 100 && mic[32_000] == 101 && mic[39_999] == 101 && mic[40_000] == 102)
    }

    @Test func flushesToDiskWhileRecording() async throws {
        let recorder = try start(flushInterval: 0.05)
        source.send(.mic, 100, seconds: 1, at: 0)
        source.send(.system, 200, seconds: 1, at: 0)
        try await waitFor { try samples(recorder.folder.systemTrackURL).count == 16_000 }

        #expect(try samples(recorder.folder.micTrackURL) == Array(repeating: 100, count: 16_000))
        #expect(try samples(recorder.folder.systemTrackURL) == Array(repeating: 200, count: 16_000))
        #expect(try recorder.folder.readStatus().state == .recording)
        try recorder.stop()
    }

    @Test func refusesToStartBelow1GBFree() throws {
        disk.bytes = 999_000_000
        #expect(throws: RecorderError.self) { try start() }
        #expect(ws.store.list().isEmpty)
    }

    @Test func warnsOnceBelow500MBFree() async throws {
        let recorder = try start(flushInterval: 0.02)
        disk.bytes = 450_000_000
        try await waitFor { !log.events.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let warnings = log.events.filter { if case .lowDisk = $0 { true } else { false } }
        #expect(warnings.count == 1)
        #expect(try recorder.folder.readStatus().state == .recording)
        try recorder.stop()
    }

    @Test func stopsCleanlyBelow200MBFree() async throws {
        let recorder = try start(flushInterval: 0.02)
        source.send(.mic, 100, seconds: 1, at: 0)
        disk.bytes = 150_000_000
        try await waitFor { log.events.contains { if case .stopped = $0 { true } else { false } } }
        source.send(.mic, 101, seconds: 1, at: 1)

        let folder = recorder.folder
        #expect(try folder.readStatus().state == .processing)
        #expect(try samples(folder.micTrackURL) == Array(repeating: 100, count: 16_000))
        #expect(try recorder.stop() == folder)
    }

    @Test func recoversARecordingMeetingAtTheLastFlushedSampleAndMarksItInterrupted() async throws {
        let crashed = try ws.store.create(startedAt: Workspace.start, language: "en")
        try sparseFile(crashed.micTrackURL, bytes: 4_320 * 32_000 + 1) // 1h 12m, torn last sample
        try sparseFile(crashed.systemTrackURL, bytes: 4_318 * 32_000)
        let processing = try ws.recordedMeeting(start: Workspace.start.addingTimeInterval(-86_400))

        let recovered = ws.store.recoverInterruptedMeetings()

        #expect(recovered.map(\.folder.id) == [crashed.id])
        let time = Workspace.start.formatted(date: .omitted, time: .shortened)
        #expect(recovered.first?.message == "Recovered your \(time) meeting, 1h 12m")
        #expect(try Data(contentsOf: crashed.micTrackURL).count == 4_320 * 32_000)
        let status = try crashed.readStatus()
        #expect(status.state == .processing && status.interrupted)
        #expect(status.endedAt == Workspace.start.addingTimeInterval(4_320))

        let queue = ProcessingQueue(store: ws.store) { [ws] in ws.options(FakeTranscription(segments: basicTracks), keepAudio: false) }
        await queue.resumePending()
        await queue.waitUntilIdle()
        #expect(try crashed.readStatus().state == .done && processing.readStatus().state == .done)
        let files = try ws.meetingFiles.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(files.filter { $0.contains("\ninterrupted: true\n") }.count == 1)
        #expect(files.count == 2)
    }
}
