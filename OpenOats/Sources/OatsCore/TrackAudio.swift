import AVFoundation

/// Reading and compressing track audio. `.pcm` files are raw 16 kHz mono Int16 (Recorder output).
public enum TrackAudio {
    public static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Length of a track in seconds.
    public static func duration(of url: URL) -> TimeInterval {
        if url.pathExtension == "pcm" {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return Double(bytes / 2) / sampleRate
        }
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// The whole track as 16 kHz mono Float samples, for backends that take samples.
    public static func samples(of url: URL) throws -> [Float] {
        var out: [Float] = []
        try forEachChunk(of: url) { buffer in
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return out
    }

    /// Writes the track as 16 kHz mono AAC `.m4a`.
    public static func compress(_ url: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try forEachChunk(of: url) { try file.write(from: $0) }
    }

    /// Streams the track in ~10 s 16 kHz mono Float buffers.
    static func forEachChunk(of url: URL, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let chunk: AVAudioFrameCount = 160_000
        if url.pathExtension == "pcm" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: Int(chunk) * 2), data.count >= 2 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2))!
                buffer.frameLength = buffer.frameCapacity
                let dst = buffer.floatChannelData![0]
                data.withUnsafeBytes { raw in
                    for i in 0..<Int(buffer.frameLength) {
                        dst[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                    }
                }
                try body(buffer)
            }
            return
        }
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw ProcessingError.unreadableAudio(url.lastPathComponent)
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
        var finished = false
        while !finished {
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            nonisolated(unsafe) var readError: Error?
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    readError = error
                }
                guard readError == nil, input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error { throw ProcessingError.unreadableAudio(url.lastPathComponent) }
            if output.frameLength > 0 { try body(output) }
            finished = status == .endOfStream || (status == .inputRanDry && output.frameLength == 0)
        }
    }
}
