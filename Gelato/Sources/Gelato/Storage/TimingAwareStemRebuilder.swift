import AVFoundation
import Foundation

enum TimingAwareStemRebuilder {
    struct PreparedSource {
        let url: URL
        let isRebuilt: Bool
    }

    private static let canonicalRates: [Double] = [
        8_000,
        12_000,
        16_000,
        22_050,
        24_000,
        32_000,
        44_100,
        48_000
    ]
    // Must sit below 0.088 so a 44.1kHz-declared stem carrying 48kHz-cadence data
    // (the most common inputNode mistag after a device switch) triggers a rebuild.
    private static let correctionThresholdRatio = 0.08
    private static let rateSnapToleranceRatio = 0.05
    private static let outputChunkFrameCapacity: AVAudioFrameCount = 16_384

    static func prepareSource(
        from url: URL?,
        chunks: [SessionAudioChunk]?,
        streamStart: Date?,
        targetSampleRate: Double? = nil,
        temporaryBasename: String
    ) throws -> PreparedSource? {
        guard let url else { return nil }

        let validChunks = SessionAudioTiming.validChunks(chunks)
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        guard shouldRebuild(validChunks, sampleRate: inputFormat.sampleRate) else {
            return PreparedSource(url: url, isRebuilt: false)
        }

        let outputURL = temporaryURL(basename: temporaryBasename)
        try? FileManager.default.removeItem(at: outputURL)
        try rebuild(
            from: url,
            to: outputURL,
            chunks: validChunks,
            streamStart: streamStart,
            targetSampleRate: targetSampleRate
        )
        return PreparedSource(url: outputURL, isRebuilt: true)
    }

    private static func shouldRebuild(
        _ chunks: [SessionAudioChunk],
        sampleRate: Double
    ) -> Bool {
        guard chunks.count > 1, sampleRate > 0 else { return false }

        let snappedRates = inferredIntervalRates(from: chunks)
        let distinctRates = Set(snappedRates.compactMap { $0 })
        if distinctRates.count > 1 {
            return true
        }

        if let onlyRate = distinctRates.first {
            let mismatchRatio = abs(onlyRate - sampleRate) / max(sampleRate, 1)
            if mismatchRatio >= correctionThresholdRatio {
                return true
            }
        }

        return false
    }

    private static func rebuild(
        from inputURL: URL,
        to outputURL: URL,
        chunks: [SessionAudioChunk],
        streamStart: Date?,
        targetSampleRate: Double?
    ) throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let outputSampleRate = targetSampleRate ?? max(inputFormat.sampleRate, 48_000)
        let channelCount = inputFormat.channelCount
        let outputFormat: AVAudioFormat
        if channelCount > 2 {
            let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
            guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
                diagLog("[AUDIO-REBUILD] cannot create output format for \(channelCount) channels, skipping rebuild")
                return
            }
            outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                interleaved: false,
                channelLayout: layout
            )
        } else {
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                diagLog("[AUDIO-REBUILD] cannot create output format, skipping rebuild")
                return
            }
            outputFormat = fmt
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        let intervalRates = inferredIntervalRates(from: chunks)
        let startReference = streamStart ?? chunks.first?.capturedAt

        for index in chunks.indices {
            let chunk = chunks[index]
            let chunkFormat = formatForChunk(
                at: index,
                chunks: chunks,
                intervalRates: intervalRates,
                defaultFormat: inputFormat
            )

            guard let inputBuffer = try readChunk(
                from: inputFile,
                format: inputFormat,
                frameCount: chunk.frameCount
            ) else {
                break
            }

            let reinterpretedBuffer = reinterpret(buffer: inputBuffer, as: chunkFormat)
            guard let convertedBuffer = try convert(
                reinterpretedBuffer,
                to: outputFormat
            ), convertedBuffer.frameLength > 0 else {
                diagLog("[AUDIO-REBUILD] chunk \(index) unconvertible, skipping")
                continue
            }
            // Writing a buffer whose format differs from the output file raises an
            // uncatchable NSException inside AVAudioFile.write — skip instead.
            guard formatsMatch(convertedBuffer.format, outputFormat) else {
                diagLog(
                    "[AUDIO-REBUILD] chunk \(index) format " +
                    "\(convertedBuffer.format.sampleRate)/\(convertedBuffer.format.channelCount)ch " +
                    "does not match output, skipping"
                )
                continue
            }

            if let startReference {
                let offsetSeconds = max(0, chunk.capturedAt.timeIntervalSince(startReference))
                let targetFrame = Int64(round(offsetSeconds * outputSampleRate))
                let gapFrames = targetFrame - outputFile.length
                if gapFrames > 0 {
                    try writeSilence(frames: gapFrames, to: outputFile, format: outputFormat)
                }
            }

            try outputFile.write(from: convertedBuffer)
        }

        diagLog(
            "[AUDIO-REBUILD] rebuilt \(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent) " +
            "sr=\(outputSampleRate)"
        )
    }

    private static func inferredIntervalRates(from chunks: [SessionAudioChunk]) -> [Double?] {
        guard chunks.count > 1 else { return [] }

        return (0..<(chunks.count - 1)).map { index in
            let current = chunks[index]
            let next = chunks[index + 1]
            let delta = next.capturedAt.timeIntervalSince(current.capturedAt)
            guard delta > 0 else { return nil }
            return snapToCanonicalRate(Double(current.frameCount) / delta)
        }
    }

    private static func formatForChunk(
        at index: Int,
        chunks: [SessionAudioChunk],
        intervalRates: [Double?],
        defaultFormat: AVAudioFormat
    ) -> AVAudioFormat {
        let inferredRate: Double?
        if index < intervalRates.count {
            inferredRate = intervalRates[index]
        } else if index > 0 {
            inferredRate = intervalRates[index - 1]
        } else {
            inferredRate = nil
        }

        guard let inferredRate else {
            return defaultFormat
        }

        let mismatchRatio = abs(inferredRate - defaultFormat.sampleRate) / max(defaultFormat.sampleRate, 1)
        guard mismatchRatio >= correctionThresholdRatio,
              let correctedFormat = makeFormat(from: defaultFormat, sampleRate: inferredRate) else {
            return defaultFormat
        }
        return correctedFormat
    }

    private static func readChunk(
        from inputFile: AVAudioFile,
        format: AVAudioFormat,
        frameCount: Int
    ) throws -> AVAudioPCMBuffer? {
        let requestedFrames = AVAudioFrameCount(max(1, frameCount))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: requestedFrames
        ) else {
            return nil
        }

        try inputFile.read(into: buffer, frameCount: requestedFrames)
        return buffer.frameLength > 0 ? buffer : nil
    }

    private static func reinterpret(
        buffer: AVAudioPCMBuffer,
        as format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        guard !formatsMatch(buffer.format, format),
              let reinterpreted = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: buffer.frameLength
              ) else {
            return buffer
        }

        reinterpreted.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(reinterpreted.mutableAudioBufferList)

        guard sourceBuffers.count == destinationBuffers.count else {
            return buffer
        }

        for index in sourceBuffers.indices {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize) else {
                return buffer
            }

            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
            destinationBuffers[index].mNumberChannels = sourceBuffers[index].mNumberChannels
        }

        return reinterpreted
    }

    /// Returns nil when the chunk cannot be converted to the output format —
    /// callers must skip the chunk rather than write a mismatched buffer.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        guard let floatSource = try convertToFloat32(buffer, format: sourceFormat) else {
            return nil
        }
        guard !formatsMatch(floatSource.format, outputFormat) else {
            return floatSource
        }

        guard let converter = AVAudioConverter(from: floatSource.format, to: outputFormat) else {
            return nil
        }

        let outputCapacity = AVAudioFrameCount(
            max(
                1,
                ceil(Double(floatSource.frameLength) * (outputFormat.sampleRate / floatSource.format.sampleRate)) + 64
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        converter.reset()
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return floatSource
        }

        if let conversionError {
            throw conversionError
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    /// Returns nil when the buffer cannot be represented/converted as float32 —
    /// callers must skip the chunk.
    private static func convertToFloat32(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let channelCount = format.channelCount
        let floatFormat: AVAudioFormat
        if channelCount > 2 {
            let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
            guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
                return nil
            }
            floatFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                interleaved: false,
                channelLayout: layout
            )
        } else {
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                return nil
            }
            floatFormat = fmt
        }
        guard !formatsMatch(format, floatFormat) else { return buffer }

        guard let converter = AVAudioConverter(from: format, to: floatFormat),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: floatFormat,
                frameCapacity: AVAudioFrameCount(max(1, buffer.frameLength + 32))
              ) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        converter.reset()
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    private static func writeSilence(
        frames: Int64,
        to outputFile: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        var remainingFrames = frames
        while remainingFrames > 0 {
            let chunkFrames = AVAudioFrameCount(min(Int64(outputChunkFrameCapacity), remainingFrames))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: chunkFrames
            ) else {
                return
            }

            buffer.frameLength = chunkFrames
            zero(buffer: buffer)
            try outputFile.write(from: buffer)
            remainingFrames -= Int64(chunkFrames)
        }
    }

    private static func zero(buffer: AVAudioPCMBuffer) {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
            lhs.channelCount == rhs.channelCount &&
            lhs.isInterleaved == rhs.isInterleaved &&
            abs(lhs.sampleRate - rhs.sampleRate) < 0.5
    }

    private static func snapToCanonicalRate(_ measuredRate: Double) -> Double? {
        guard measuredRate.isFinite,
              let nearestRate = canonicalRates.min(by: { abs($0 - measuredRate) < abs($1 - measuredRate) }) else {
            return nil
        }

        let tolerance = nearestRate * rateSnapToleranceRatio
        guard abs(nearestRate - measuredRate) <= tolerance else { return nil }
        return nearestRate
    }

    private static func makeFormat(from format: AVAudioFormat, sampleRate: Double) -> AVAudioFormat? {
        var streamDescription = format.streamDescription.pointee
        streamDescription.mSampleRate = sampleRate
        return AVAudioFormat(streamDescription: &streamDescription)
    }

    private static func temporaryURL(basename: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GelatoAudioRepairs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(basename).caf")
    }
}
