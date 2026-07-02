@preconcurrency import AVFoundation
import Foundation

final class SessionAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.gelato.session-audio-recorder")
    /// Timing-JSON checkpoints run here, off the stem write queue — encoding the
    /// full chunk history must never delay audio writes.
    private let checkpointQueue = DispatchQueue(label: "com.gelato.session-audio-timing", qos: .utility)
    private static let drainTimeoutSeconds: TimeInterval = 30
    private var micWriter: PCMFileWriter?
    private var systemWriter: PCMFileWriter?
    private var timingURL: URL?
    private var micFirstBufferAt: Date?
    private var systemFirstBufferAt: Date?
    private var micChunks: [SessionAudioChunk] = []
    private var systemChunks: [SessionAudioChunk] = []
    private var lastCheckpointAt: Date?

    func start(sessionID: String, in directory: URL) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            diagLog("[AUDIO-RECORDER-START-FAIL] cannot create \(directory.path): \(error.localizedDescription)")
        }

        let micURL = directory.appendingPathComponent("\(sessionID)_you.caf")
        let systemURL = directory.appendingPathComponent("\(sessionID)_them.caf")
        let timingURL = directory.appendingPathComponent("\(sessionID).audio-timing.json")

        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
        try? FileManager.default.removeItem(at: timingURL)

        micWriter = PCMFileWriter(url: micURL)
        systemWriter = PCMFileWriter(url: systemURL)
        self.timingURL = timingURL
        micFirstBufferAt = nil
        systemFirstBufferAt = nil
        micChunks = []
        systemChunks = []
        lastCheckpointAt = nil
    }

    func appendMicBuffer(_ capturedBuffer: CapturedAudioBuffer) {
        append(capturedBuffer, isMic: true)
    }

    /// Reset the system writer's converter so it re-locks to the next buffer's
    /// format. Call this when the system audio capture restarts (e.g. output device change)
    /// so the writer rebuilds its converter for the new-device format.
    func resetSystemFormat() {
        lock.lock()
        systemWriter?.resetTargetFormat()
        lock.unlock()
    }

    func appendSystemBuffer(_ capturedBuffer: CapturedAudioBuffer) {
        append(capturedBuffer, isMic: false)
    }

    private func append(_ capturedBuffer: CapturedAudioBuffer, isMic: Bool) {
        lock.lock()
        let writer = isMic ? micWriter : systemWriter
        if writer != nil {
            if isMic, micFirstBufferAt == nil {
                micFirstBufferAt = capturedBuffer.capturedAt
            } else if !isMic, systemFirstBufferAt == nil {
                systemFirstBufferAt = capturedBuffer.capturedAt
            }
        }
        lock.unlock()

        guard let writer,
              let copy = capturedBuffer.buffer.ownedCopy(),
              let preparedBuffer = writer.prepareBufferForWriting(copy) else { return }
        guard preparedBuffer.frameLength > 0 else { return }

        let capturedAt = capturedBuffer.capturedAt
        writeQueue.async { [weak self] in
            // Record the timing chunk only if the write actually succeeded, so the
            // timing JSON never claims frames that aren't in the file (a mismatch
            // makes the mixer throw "time range beyond duration" at finalization).
            guard writer.appendPreparedBuffer(preparedBuffer) else { return }
            self?.recordChunk(
                SessionAudioChunk(capturedAt: capturedAt, frameCount: Int(preparedBuffer.frameLength)),
                isMic: isMic
            )
        }
    }

    /// Runs on writeQueue.
    private func recordChunk(_ chunk: SessionAudioChunk, isMic: Bool) {
        lock.lock()
        if isMic {
            micChunks.append(chunk)
        } else {
            systemChunks.append(chunk)
        }

        // Checkpoint the timing JSON so a crash mid-session doesn't lose all
        // timing metadata. Each checkpoint re-encodes the full history, so the
        // interval grows with session length to keep cumulative cost bounded.
        let totalChunks = micChunks.count + systemChunks.count
        let minInterval = max(10.0, Double(totalChunks) / 400.0)
        let now = Date()
        let shouldCheckpoint: Bool
        if let lastCheckpointAt {
            shouldCheckpoint = now.timeIntervalSince(lastCheckpointAt) >= minInterval
        } else {
            shouldCheckpoint = totalChunks >= 20
        }
        if shouldCheckpoint {
            lastCheckpointAt = now
        }
        let timing = shouldCheckpoint ? currentTimingLocked() : nil
        let timingURL = self.timingURL
        lock.unlock()

        if let timing, let timingURL {
            checkpointQueue.async {
                Self.writeTiming(timing, to: timingURL)
            }
        }
    }

    /// Caller must hold `lock`.
    private func currentTimingLocked() -> SessionAudioTiming {
        SessionAudioTiming(
            micFirstBufferAt: micFirstBufferAt,
            systemFirstBufferAt: systemFirstBufferAt,
            micChunks: micChunks,
            systemChunks: systemChunks
        )
    }

    private static func writeTiming(_ timing: SessionAudioTiming, to url: URL) {
        let encoder = SessionAudioTiming.makeJSONEncoder()
        do {
            let data = try encoder.encode(timing)
            try data.write(to: url, options: .atomic)
        } catch {
            diagLog("[AUDIO-TIMING-WRITE-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        let micWriter = self.micWriter
        let systemWriter = self.systemWriter
        self.micWriter = nil
        self.systemWriter = nil
        lock.unlock()

        let drainSignal = DispatchSemaphore(value: 0)
        writeQueue.async {
            micWriter?.finish()
            systemWriter?.finish()
            drainSignal.signal()
        }

        let drained = drainSignal.wait(timeout: .now() + Self.drainTimeoutSeconds) == .success
        if drained {
            diagLog("[AUDIO-RECORDER-FINISH] drained queued writes")
        } else {
            diagLog("[AUDIO-RECORDER-FINISH-TIMEOUT] continuing after \(Self.drainTimeoutSeconds)s")
            // Force-finish the writers NOW: straggler writes still queued behind
            // the backlog must hit the isFinished guard instead of appending
            // old-session audio and timing chunks after a new session starts.
            micWriter?.finish()
            systemWriter?.finish()
        }

        // Snapshot chunks AFTER the drain so the timing JSON reflects every write
        // that made it into the stems.
        lock.lock()
        let timing = currentTimingLocked()
        let timingURL = self.timingURL
        self.timingURL = nil
        self.micFirstBufferAt = nil
        self.systemFirstBufferAt = nil
        self.micChunks = []
        self.systemChunks = []
        self.lastCheckpointAt = nil
        lock.unlock()

        diagLog(
            "[AUDIO-RECORDER-FINISH] micChunks=\(timing.micChunks?.count ?? 0) " +
            "systemChunks=\(timing.systemChunks?.count ?? 0)"
        )

        guard let timingURL else { return drained }
        guard timing.micFirstBufferAt != nil || timing.systemFirstBufferAt != nil else { return drained }

        // Route the final write through checkpointQueue so a still-queued periodic
        // checkpoint can't land after it and replace the final JSON with a stale one.
        checkpointQueue.sync {
            Self.writeTiming(timing, to: timingURL)
        }
        return drained
    }
}

private final class PCMFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var audioFile: AVAudioFile?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var isFinished = false
    private var zeroOutputStreak = 0
    private static let zeroOutputRebuildThreshold = 30

    init(url: URL) {
        self.url = url
    }

    /// Rebuild the converter for the next buffer's format. The locked target format
    /// is kept — the file was created with it and all audio must convert to it.
    func resetTargetFormat() {
        lock.lock()
        converter = nil
        converterInputFormat = nil
        zeroOutputStreak = 0
        lock.unlock()
    }

    func prepareBufferForWriting(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return nil }

        if targetFormat == nil {
            targetFormat = buffer.format
            converter = nil
            converterInputFormat = nil
            return buffer
        }

        guard let targetFormat else { return nil }
        guard !Self.formatsMatch(buffer.format, targetFormat) else { return buffer }

        if converter == nil || converterInputFormat.map({ !Self.formatsMatch($0, buffer.format) }) != false {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
            zeroOutputStreak = 0
        }

        guard let activeConverter = converter else {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): converter unavailable")
            return nil
        }

        if let convertedBuffer = convert(buffer, to: targetFormat, using: activeConverter) {
            if convertedBuffer.frameLength == 0 {
                // A priming converter can legitimately hold frames back, but a
                // converter stuck at zero output forever would silently drop the
                // rest of the stem — rebuild it after a sustained streak.
                zeroOutputStreak += 1
                if zeroOutputStreak >= Self.zeroOutputRebuildThreshold {
                    diagLog("[AUDIO-WRITE-CONVERT] \(url.lastPathComponent): rebuilding stalled converter")
                    converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                    converterInputFormat = buffer.format
                    zeroOutputStreak = 0
                }
            } else {
                zeroOutputStreak = 0
            }
            return convertedBuffer
        }

        // Conversion errored — rebuild once and retry with the fresh converter.
        converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        converterInputFormat = buffer.format
        zeroOutputStreak = 0

        guard let freshConverter = converter,
              let convertedBuffer = convert(buffer, to: targetFormat, using: freshConverter) else {
            diagLog(
                "[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): " +
                "conversion produced no output frames"
            )
            return nil
        }
        return convertedBuffer
    }

    @discardableResult
    func appendPreparedBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // A buffer that raced past finish() must never lazily re-create the file:
        // AVAudioFile(forWriting:) truncates, erasing the entire recorded stem.
        guard !isFinished else {
            diagLog("[AUDIO-WRITE-DROP] \(url.lastPathComponent): buffer arrived after finish")
            return false
        }

        if let targetFormat, !Self.formatsMatch(buffer.format, targetFormat) {
            diagLog(
                "[AUDIO-WRITE-DROP] \(url.lastPathComponent): buffer format " +
                "\(buffer.format.sampleRate)/\(buffer.format.channelCount)ch does not match file format"
            )
            return false
        }

        do {
            if audioFile == nil {
                let outputFormat = targetFormat ?? buffer.format
                targetFormat = outputFormat
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: outputFormat.settings,
                    commonFormat: outputFormat.commonFormat,
                    interleaved: outputFormat.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
            return true
        } catch {
            diagLog("[AUDIO-WRITE-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved &&
            abs(lhs.sampleRate - rhs.sampleRate) < 0.5
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let outputCapacity = AVAudioFrameCount(
            max(
                1,
                ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 64
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): output buffer allocation failed")
            return nil
        }

        // Streaming conversion: the converter keeps its resampler state across
        // buffers (no reset()). Answering .noDataNow — instead of .endOfStream —
        // tells it more input will follow, avoiding an audible discontinuity at
        // every buffer boundary in rate-converted stems.
        var error: NSError?
        var didProvideInput = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            diagLog("[AUDIO-WRITE-CONVERT-FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    func finish() {
        lock.lock()
        // Drain the streaming converter's held-back tail into the file before
        // closing — a rate-converting AVAudioConverter holds ~latency frames
        // until it sees .endOfStream.
        if let converter, let targetFormat, let audioFile,
           let tailBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) {
            var drainError: NSError?
            converter.convert(to: tailBuffer, error: &drainError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if drainError == nil, tailBuffer.frameLength > 0 {
                do {
                    try audioFile.write(from: tailBuffer)
                } catch {
                    diagLog("[AUDIO-WRITE-FAIL] \(url.lastPathComponent): tail drain \(error.localizedDescription)")
                }
            }
        }
        isFinished = true
        audioFile = nil
        targetFormat = nil
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }
}

private extension AVAudioPCMBuffer {
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        copy.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)

            guard let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                return nil
            }

            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
            destinationBuffers[index].mNumberChannels = source.mNumberChannels
        }

        return copy
    }
}
