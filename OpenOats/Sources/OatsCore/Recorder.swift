import Foundation
import os

/// A Meeting's audio tracks: the Mic track and System track the Recorder writes, or one mixed track from an import.
public enum Track: String, Sendable, CaseIterable { case mic, system, mixed }

/// 16 kHz mono audio from one track. `hostTime` is when the first sample was captured, in seconds on the
/// Recorder's clock (default `ProcessInfo.systemUptime`, i.e. mach host time).
public struct CapturedAudio: Sendable {
    public var track: Track
    public var samples: [Int16]
    public var hostTime: TimeInterval

    public init(track: Track, samples: [Int16], hostTime: TimeInterval) {
        self.track = track
        self.samples = samples
        self.hostTime = hostTime
    }

    public init(track: Track, floats: [Float], hostTime: TimeInterval) {
        self.init(track: track, samples: floats.map { Int16(max(-1, min(1, $0)) * 32767) }, hostTime: hostTime)
    }
}

/// Mic and system capture. Gaps and device changes show up as jumps in `hostTime`; the Recorder writes silence over them.
public protocol CaptureSource: Sendable {
    /// `deliver` may be called on any thread.
    func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws
    func stop()
}

public enum RecorderEvent: Sendable {
    /// Free disk space fell below 500 MB (sent once).
    case lowDisk(freeBytes: Int64)
    /// The Recorder stopped by itself (disk almost full, or a write failed); the Meeting is ready to queue.
    case stopped(MeetingFolder, reason: String)
}

public enum RecorderError: LocalizedError {
    case notEnoughDisk(freeBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .notEnoughDisk(free):
            "Not enough disk space to record (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free, 1 GB needed)."
        }
    }
}

/// Writes a Meeting's tracks as raw PCM (`mic.pcm`, `system.pcm`), flushed every `flushInterval` seconds,
/// so an abrupt end loses at most that much audio (ADR 0004).
public final class Recorder: @unchecked Sendable {
    public static let startMinimum: Int64 = 1_000_000_000
    public static let warnBelow: Int64 = 500_000_000
    public static let stopBelow: Int64 = 200_000_000
    /// Timestamp jitter tolerated before writing silence (gap) or dropping overlap: 100 ms.
    static let slack = 1_600

    public let folder: MeetingFolder
    private let source: any CaptureSource
    private let clock: @Sendable () -> TimeInterval
    private let freeSpace: @Sendable (URL) -> Int64
    private let onEvent: @Sendable (RecorderEvent) -> Void
    private let queue = DispatchQueue(label: "openoats.recorder", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0
    private var writers: [Track: Writer] = [:]
    private var lock: MeetingLock?
    /// Written on the recorder queue, read by the level meters without waiting on it.
    private let trackLevels = OSAllocatedUnfairLock(initialState: [Track: Float]())
    private var warned = false
    private var finished = false

    private struct Writer {
        let handle: FileHandle
        var written = 0
        var pending: [Int16] = []
        var position: Int { written + pending.count }
    }

    /// Creates a Meeting in state `recording` and starts capturing into it. If capture can't start, the new Meeting
    /// folder is removed again.
    public static func start(
        store: MeetingStore, source: any CaptureSource, language: String?, flushInterval: TimeInterval = 2,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        freeSpace: @escaping @Sendable (URL) -> Int64 = Recorder.freeSpace,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void = { _ in }
    ) throws -> Recorder {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let free = freeSpace(store.root)
        guard free >= startMinimum else { throw RecorderError.notEnoughDisk(freeBytes: free) }
        let folder = try store.create(language: language)
        do {
            let recorder = try Recorder(folder: folder, source: source, clock: clock, freeSpace: freeSpace, onEvent: onEvent)
            try recorder.begin(flushInterval: flushInterval)
            return recorder
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
    }

    private init(folder: MeetingFolder, source: any CaptureSource, clock: @escaping @Sendable () -> TimeInterval,
                 freeSpace: @escaping @Sendable (URL) -> Int64, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        self.folder = folder
        self.source = source
        self.clock = clock
        self.freeSpace = freeSpace
        self.onEvent = onEvent
        lock = try folder.lock()
        for (track, url) in [(Track.mic, folder.micTrackURL), (.system, folder.systemTrackURL)] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            writers[track] = Writer(handle: try FileHandle(forWritingTo: url))
        }
    }

    private func begin(flushInterval: TimeInterval) throws {
        startTime = clock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
        do {
            try source.start { [weak self] chunk in self?.queue.async { self?.append(chunk) } }
        } catch {
            source.stop()
            queue.sync {
                finished = true
                timer.cancel()
                writers.values.forEach { try? $0.handle.close() }
                lock = nil
            }
            throw error
        }
    }

    /// Current RMS level per track, 0…1, for the level meters.
    public var levels: [Track: Float] { trackLevels.withLock { $0 } }

    /// Stops capture, writes what's left, and moves the Meeting to `processing` (queue it next).
    @discardableResult
    public func stop() throws -> MeetingFolder {
        source.stop()
        try queue.sync { try finish() }
        return folder
    }

    private func append(_ chunk: CapturedAudio) {
        guard !finished, var writer = writers[chunk.track] else { return }
        let offset = Int(((chunk.hostTime - startTime) * TrackAudio.sampleRate).rounded())
        var samples = chunk.samples[...]
        if offset > writer.position + Self.slack {
            writer.pending += repeatElement(0, count: offset - writer.position)
        } else if offset < writer.position - Self.slack {
            samples = samples.dropFirst(writer.position - offset)
        }
        writer.pending += samples
        writers[chunk.track] = writer
        let squares = chunk.samples.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        let level = min(1, (squares / Float(max(1, chunk.samples.count))).squareRoot() / 32768 * 25)
        trackLevels.withLock { $0[chunk.track] = level }
    }

    private func flush() {
        guard !finished else { return }
        let free = freeSpace(folder.url)
        do {
            try write()
            if free < Self.stopBelow {
                try finish()
                onEvent(.stopped(folder, reason: "Recording stopped: the disk is almost full."))
            } else if free < Self.warnBelow, !warned {
                warned = true
                onEvent(.lowDisk(freeBytes: free))
            }
        } catch {
            try? finish()
            onEvent(.stopped(folder, reason: "Recording stopped: \(error.localizedDescription)"))
        }
    }

    /// Appends pending samples to the track files and syncs them to disk.
    private func write() throws {
        for (track, var writer) in writers where !writer.pending.isEmpty {
            try writer.pending.withUnsafeBufferPointer { try writer.handle.write(contentsOf: Data(buffer: $0)) }
            try writer.handle.synchronize()
            writer.written += writer.pending.count
            writer.pending.removeAll(keepingCapacity: true)
            writers[track] = writer
        }
    }

    private func finish() throws {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        defer {
            writers.values.forEach { try? $0.handle.close() }
            lock = nil
        }
        try write()
        try folder.updateStatus {
            $0.state = .processing
            $0.endedAt = Date()
        }
    }

    /// Free space for important data on the volume holding `url`.
    public static func freeSpace(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

/// A Meeting found in `recording` on launch and closed by `recoverInterruptedMeetings()`.
public struct RecoveredMeeting: Sendable, Equatable {
    public var folder: MeetingFolder
    public var startedAt: Date
    public var duration: TimeInterval

    /// Notification text, e.g. "Recovered your 10:02 meeting, 1h 12m".
    public var message: String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = duration < 60 ? [.second] : [.hour, .minute]
        return "Recovered your \(startedAt.formatted(date: .omitted, time: .shortened)) meeting, \(f.string(from: duration) ?? "")"
    }
}

extension MeetingStore {
    /// On launch, before `ProcessingQueue.resumePending()`: closes Meetings left in `recording` at their last flushed
    /// sample, marks them Interrupted and moves them to `processing`. Skips Meetings another process is still recording.
    public func recoverInterruptedMeetings() -> [RecoveredMeeting] {
        list().compactMap { folder in
            guard let status = try? folder.readStatus(), status.state == .recording, let lock = try? folder.lock() else { return nil }
            defer { withExtendedLifetime(lock) {} }
            var duration: TimeInterval = 0
            for url in [folder.micTrackURL, folder.systemTrackURL] {
                guard let handle = try? FileHandle(forWritingTo: url) else { continue }
                if let size = try? handle.seekToEnd(), size % 2 == 1 { try? handle.truncate(atOffset: size - 1) }
                try? handle.close()
                duration = max(duration, TrackAudio.duration(of: url))
            }
            let updated = try? folder.updateStatus {
                $0.state = .processing
                $0.interrupted = true
                $0.endedAt = $0.startedAt.addingTimeInterval(duration)
            }
            return updated.map { RecoveredMeeting(folder: folder, startedAt: $0.startedAt, duration: duration) }
        }
    }
}
