@preconcurrency import AVFoundation

/// Records mic and system audio to temporary CAF files during a session,
/// then merges and encodes them into a single M4A (AAC) file on finalization.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?
    private var micTempURL: URL?
    private var sysTempURL: URL?
    private var outputDirectory: URL
    private var sessionTimestamp = ""
    private var micWriteCount = 0
    private var sysWriteCount = 0

    /// Wall-clock timestamp of the first buffer write for each stream.
    private var micStartDate: Date?
    private var sysStartDate: Date?

    /// Timing anchors mapping frame positions to wall-clock dates.
    private(set) var micAnchors: [(frame: Int64, date: Date)] = []
    private(set) var sysAnchors: [(frame: Int64, date: Date)] = []

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func updateDirectory(_ url: URL) {
        lock.withLock { outputDirectory = url }
    }

    func startSession() {
        lock.withLock {
            micFile = nil
            sysFile = nil
            micWriteCount = 0
            sysWriteCount = 0
            micStartDate = nil
            sysStartDate = nil
            micAnchors = []
            sysAnchors = []

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm"
            sessionTimestamp = fmt.string(from: Date())

            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            micTempURL = tmp.appendingPathComponent("openoats_mic_\(sessionTimestamp).caf")
            sysTempURL = tmp.appendingPathComponent("openoats_sys_\(sessionTimestamp).caf")
        }
    }

    func writeMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)

            // Lazily create file as mono at the source sample rate
            if micFile == nil, let url = micTempURL {
                guard let monoFormat = AVAudioFormat(
                    standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1
                ) else {
                    diagLog("[RECORDER] mic file SKIP: cannot create mono format at \(buffer.format.sampleRate)Hz")
                    return
                }
                do {
                    micFile = try AVAudioFile(forWriting: url, settings: monoFormat.settings)
                    diagLog("[RECORDER] mic file created: \(url.lastPathComponent) mono at \(buffer.format.sampleRate)Hz")
                } catch {
                    diagLog("[RECORDER] mic file creation FAILED: \(error)")
                    return
                }
            }

            // Record timing anchor on first write
            if micStartDate == nil {
                let now = Date()
                micStartDate = now
                micAnchors.append((frame: micFile?.length ?? 0, date: now))
            }

            // Downmix to mono inline — handle float32, int16, and int32 formats
            guard let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1
            ),
            let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
            let dst = monoBuf.floatChannelData?[0] else { return }
            monoBuf.frameLength = buffer.frameLength

            if let src = buffer.floatChannelData {
                if channels == 1 {
                    if buffer.format.isInterleaved {
                        memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                    } else {
                        memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                    }
                } else {
                    let scale = 1.0 / Float(channels)
                    if buffer.format.isInterleaved {
                        for i in 0..<frames {
                            var sum: Float = 0
                            for ch in 0..<channels { sum += src[0][(i * channels) + ch] }
                            dst[i] = sum * scale
                        }
                    } else {
                        for i in 0..<frames {
                            var sum: Float = 0
                            for ch in 0..<channels { sum += src[ch][i] }
                            dst[i] = sum * scale
                        }
                    }
                }
            } else if let src = buffer.int16ChannelData {
                let scale = 1.0 / Float(Int16.max)
                if channels == 1 {
                    for i in 0..<frames { dst[i] = Float(src[0][i]) * scale }
                } else if buffer.format.isInterleaved {
                    let invCh = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += Float(src[0][(i * channels) + ch]) * scale }
                        dst[i] = sum * invCh
                    }
                } else {
                    let invCh = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += Float(src[ch][i]) * scale }
                        dst[i] = sum * invCh
                    }
                }
            } else if let src = buffer.int32ChannelData {
                let scale = 1.0 / Float(Int32.max)
                if channels == 1 {
                    for i in 0..<frames { dst[i] = Float(src[0][i]) * scale }
                } else if buffer.format.isInterleaved {
                    let invCh = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += Float(src[0][(i * channels) + ch]) * scale }
                        dst[i] = sum * invCh
                    }
                } else {
                    let invCh = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += Float(src[ch][i]) * scale }
                        dst[i] = sum * invCh
                    }
                }
            } else {
                diagLog("[RECORDER] mic write SKIP: unsupported buffer format \(buffer.format.commonFormat.rawValue)")
                return
            }

            micWriteCount += 1
            if micWriteCount <= 5 || micWriteCount % 100 == 0 {
                let peak = Self.peakLevel(monoBuf)
                diagLog("[RECORDER] mic write #\(micWriteCount): frames=\(frames) peak=\(peak)")
            }
            do {
                try micFile?.write(from: monoBuf)
            } catch {
                diagLog("[RECORDER] mic write ERROR: \(error)")
            }
        }
    }

    func writeSysBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }
            if sysFile == nil, let url = sysTempURL {
                do {
                    sysFile = try AVAudioFile(
                        forWriting: url,
                        settings: buffer.format.settings,
                        commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved
                    )
                } catch {
                    diagLog("[RECORDER] sys file creation FAILED: \(error)")
                    return
                }
            }

            // Record timing anchor on first write
            if sysStartDate == nil {
                let now = Date()
                sysStartDate = now
                sysAnchors.append((frame: sysFile?.length ?? 0, date: now))
            }

            do {
                try sysFile?.write(from: buffer)
            } catch {
                diagLog("[RECORDER] sys write ERROR: \(error)")
            }
        }
    }

    /// Read-only access to current temp file URLs (for copying before finalize).
    func tempFileURLs() -> (mic: URL?, sys: URL?) {
        lock.withLock { (micTempURL, sysTempURL) }
    }

    /// Read-only access to timing anchor data.
    func timingAnchors() -> (
        micStartDate: Date?, sysStartDate: Date?,
        micAnchors: [(frame: Int64, date: Date)],
        sysAnchors: [(frame: Int64, date: Date)]
    ) {
        lock.withLock {
            (micStartDate, sysStartDate, micAnchors, sysAnchors)
        }
    }

    /// Close file handles without merging or deleting temp files.
    /// Returns the temp CAF URLs and timing data for batch transcription.
    func sealForBatch() -> (
        mic: URL?, sys: URL?,
        micStartDate: Date?, sysStartDate: Date?,
        micAnchors: [(frame: Int64, date: Date)],
        sysAnchors: [(frame: Int64, date: Date)]
    ) {
        lock.withLock {
            micFile = nil
            sysFile = nil
            let result = (
                mic: micTempURL, sys: sysTempURL,
                micStartDate: self.micStartDate, sysStartDate: self.sysStartDate,
                micAnchors: self.micAnchors, sysAnchors: self.sysAnchors
            )
            micTempURL = nil
            sysTempURL = nil
            return result
        }
    }

    /// Discard the current recording without merging or encoding.
    /// Closes file handles and removes temp CAF files.
    func discardRecording() {
        lock.withLock {
            micFile = nil
            sysFile = nil
        }
        cleanupTempFiles()
    }

    func finalizeRecording() async {
        let alreadySealed: Bool = lock.withLock {
            let sealed = micFile == nil && sysFile == nil && micTempURL == nil && sysTempURL == nil
            if !sealed {
                micFile = nil
                sysFile = nil
            }
            return sealed
        }

        guard !alreadySealed else { return }

        await Task.detached(priority: .userInitiated) { [self] in
            self.mergeAndEncode()
            self.cleanupTempFiles()
        }.value
    }

    // MARK: - Private

    private func cleanupTempFiles() {
        lock.withLock {
            let fm = FileManager.default
            if let url = micTempURL { try? fm.removeItem(at: url) }
            if let url = sysTempURL { try? fm.removeItem(at: url) }
            micTempURL = nil
            sysTempURL = nil
        }
    }

    private func mergeAndEncode() {
        let (micURL, sysURL, dir, timestamp) = lock.withLock {
            (micTempURL, sysTempURL, outputDirectory, sessionTimestamp)
        }

        let micReader: AVAudioFile? = {
            guard let url = micURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }()
        let sysReader: AVAudioFile? = {
            guard let url = sysURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }()

        guard micReader != nil || sysReader != nil else {
            diagLog("[RECORDER] No audio data recorded")
            return
        }

        let targetRate: Double = 48_000
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1) else { return }

        if let mic = micReader {
            diagLog("[RECORDER] mic temp: \(mic.length) frames, format=\(mic.processingFormat)")
        }
        if let sys = sysReader {
            diagLog("[RECORDER] sys temp: \(sys.length) frames, format=\(sys.processingFormat)")
        }

        let micSamples = Self.readAllMono(file: micReader, targetRate: targetRate, targetFormat: targetFormat)
        let sysSamples = Self.readAllMono(file: sysReader, targetRate: targetRate, targetFormat: targetFormat)

        let micPeak = micSamples.reduce(Float(0)) { max($0, abs($1)) }
        let sysPeak = sysSamples.reduce(Float(0)) { max($0, abs($1)) }
        diagLog("[RECORDER] after readAllMono: micSamples=\(micSamples.count) micPeak=\(micPeak) sysSamples=\(sysSamples.count) sysPeak=\(sysPeak)")

        let length = max(micSamples.count, sysSamples.count)
        guard length > 0 else { return }

        let outputURL = dir.appendingPathComponent("\(timestamp).m4a")
        guard let outputFile = try? AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else {
            diagLog("[RECORDER] Failed to create output file")
            return
        }

        // Write mixed audio in chunks
        let chunkSize = 65_536
        var offset = 0
        while offset < length {
            let count = min(chunkSize, length - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)

            for i in 0..<count {
                let m: Float = offset + i < micSamples.count ? micSamples[offset + i] : 0
                let s: Float = offset + i < sysSamples.count ? sysSamples[offset + i] : 0
                out[i] = max(-1, min(1, m + s))
            }

            do { try outputFile.write(from: buffer) } catch { break }
            offset += count
        }

        diagLog("[RECORDER] Saved \(outputURL.lastPathComponent) (\(length) frames)")
    }

    private static func readAllMono(file: AVAudioFile?, targetRate: Double, targetFormat: AVAudioFormat) -> [Float] {
        guard let file, file.length > 0 else { return [] }

        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return [] }
        do { try file.read(into: readBuf) } catch { return [] }

        // Already at target format — extract directly
        if srcFormat.sampleRate == targetRate && srcFormat.channelCount == 1 {
            return extractSamples(from: readBuf)
        }

        // Resample and/or downmix via AVAudioConverter
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            return extractMonoSamples(from: readBuf)
        }

        let ratio = targetRate / srcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return [] }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return readBuf
        }

        return extractSamples(from: outBuf)
    }

    private static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<count {
                peak = max(peak, abs(data[ch][i]))
            }
        }
        return peak
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels <= 1 { return extractSamples(from: buffer) }

        let scale = 1.0 / Float(channels)
        return (0..<count).map { i in
            var sum: Float = 0
            for ch in 0..<channels { sum += data[ch][i] }
            return sum * scale
        }
    }
}
