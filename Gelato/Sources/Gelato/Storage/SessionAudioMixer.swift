import AVFoundation
import Foundation

enum SessionAudioMixer {
    static func createCombinedAudio(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL,
        audioTiming: SessionAudioTiming? = nil
    ) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            try await createCombinedAudioSync(
                micURL: micURL,
                systemURL: systemURL,
                outputURL: outputURL,
                audioTiming: audioTiming
            )
        }.value
    }

    /// Volume boost applied to the microphone track so it matches system audio
    /// loudness in the combined mix. Mic input is typically much quieter than
    /// system audio routed through a process tap.
    private static let micVolumeBoost: Float = 9.0

    private static func createCombinedAudioSync(
        micURL: URL?,
        systemURL: URL?,
        outputURL: URL,
        audioTiming: SessionAudioTiming? = nil
    ) async throws -> URL? {
        guard micURL != nil || systemURL != nil else { return nil }

        try? FileManager.default.removeItem(at: outputURL)
        var temporaryURLs: [URL] = []
        defer {
            for temporaryURL in temporaryURLs {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let composition = AVMutableComposition()
        let combinedOrigin = [audioTiming?.micFirstBufferAt, audioTiming?.systemFirstBufferAt]
            .compactMap { $0 }
            .min()

        var micTrackID: CMPersistentTrackID?

        if let micURL {
            let preparedMic = try TimingAwareStemRebuilder.prepareSource(
                from: micURL,
                chunks: audioTiming?.micChunks,
                streamStart: audioTiming?.micFirstBufferAt,
                temporaryBasename: "\(outputURL.deletingPathExtension().lastPathComponent)-mic"
            )
            if preparedMic?.isRebuilt == true, let preparedMic {
                temporaryURLs.append(preparedMic.url)
            }
            micTrackID = try await insertTrack(
                from: preparedMic?.url ?? micURL,
                into: composition,
                at: insertionTime(
                    for: audioTiming?.micFirstBufferAt,
                    relativeTo: combinedOrigin,
                    trustRoundedOffsets: false
                ),
                chunks: preparedMic?.isRebuilt == true ? nil : audioTiming?.micChunks,
                streamStart: preparedMic?.isRebuilt == true ? nil : audioTiming?.micFirstBufferAt
            )
        }

        if let systemURL {
            // Compute the effective sample rate from wall-clock timing (OpenOats approach).
            // The process tap can deliver far more frames than real-time after a device
            // switch, so the declared sample rate in the CAF file may be wrong.
            let effectiveSystemURL: URL
            let addedTempURL: Bool
            if let effectiveRate = Self.effectiveSampleRate(
                url: systemURL,
                chunks: audioTiming?.systemChunks,
                firstBufferAt: audioTiming?.systemFirstBufferAt
            ) {
                let resampledURL = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(outputURL.deletingPathExtension().lastPathComponent)-system-resampled.caf"
                    )
                if let resampled = try? Self.resampleToCorrectDuration(
                    sourceURL: systemURL,
                    outputURL: resampledURL,
                    effectiveRate: effectiveRate
                ) {
                    effectiveSystemURL = resampled
                    temporaryURLs.append(resampled)
                    addedTempURL = true
                } else {
                    effectiveSystemURL = systemURL
                    addedTempURL = false
                }
            } else {
                effectiveSystemURL = systemURL
                addedTempURL = false
            }

            let preparedSystem = try TimingAwareStemRebuilder.prepareSource(
                from: effectiveSystemURL,
                chunks: addedTempURL ? nil : audioTiming?.systemChunks,
                streamStart: addedTempURL ? nil : audioTiming?.systemFirstBufferAt,
                temporaryBasename: "\(outputURL.deletingPathExtension().lastPathComponent)-system"
            )
            if preparedSystem?.isRebuilt == true, let preparedSystem {
                temporaryURLs.append(preparedSystem.url)
            }
            try await insertTrack(
                from: preparedSystem?.url ?? effectiveSystemURL,
                into: composition,
                at: insertionTime(
                    for: audioTiming?.systemFirstBufferAt,
                    relativeTo: combinedOrigin,
                    trustRoundedOffsets: false
                ),
                chunks: (preparedSystem?.isRebuilt == true || addedTempURL) ? nil : audioTiming?.systemChunks,
                streamStart: (preparedSystem?.isRebuilt == true || addedTempURL) ? nil : audioTiming?.systemFirstBufferAt
            )
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }

        // Boost the mic track volume so it matches system audio loudness.
        if let micTrackID,
           let micCompositionTrack = composition.track(withTrackID: micTrackID) {
            let micParams = AVMutableAudioMixInputParameters(track: micCompositionTrack)
            micParams.trackID = micTrackID
            micParams.setVolume(micVolumeBoost, at: .zero)

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [micParams]
            exporter.audioMix = audioMix
        }

        try await exporter.export(to: outputURL, as: .mp4)

        return outputURL
    }

    /// Inserts an audio file as a new track in the composition.
    /// Returns the track ID of the inserted composition track, or `nil` if insertion failed.
    @discardableResult
    private static func insertTrack(
        from url: URL,
        into composition: AVMutableComposition,
        at startTime: CMTime,
        chunks: [SessionAudioChunk]?,
        streamStart: Date?
    ) async throws -> CMPersistentTrackID? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return nil
        }

        let audioFile = try AVAudioFile(forReading: url)
        let validChunks = SessionAudioTiming.validChunks(chunks)
        let useChunkTiming = SessionAudioTiming.shouldUseChunkTiming(
            validChunks,
            sampleRate: audioFile.processingFormat.sampleRate
        )

        if !validChunks.isEmpty, let streamStart, useChunkTiming {
            let sampleRate = audioFile.processingFormat.sampleRate
            let fileDurationSeconds = Double(audioFile.length) / sampleRate
            var sourceCursor: Double = 0

            for chunk in validChunks {
                let chunkDurationSeconds = Double(chunk.frameCount) / sampleRate
                // Clamp to the actual file length — the timing JSON can claim more
                // frames than the stem holds (e.g. a write failed mid-session), and
                // inserting a range beyond the track duration throws, aborting the
                // whole combined-audio export.
                let clampedDurationSeconds = min(
                    chunkDurationSeconds,
                    max(0, fileDurationSeconds - sourceCursor)
                )
                guard clampedDurationSeconds > 0.000_1 else { break }
                let chunkDuration = CMTime(
                    seconds: clampedDurationSeconds,
                    preferredTimescale: 60_000
                )
                let sourceTime = CMTime(
                    seconds: sourceCursor,
                    preferredTimescale: 60_000
                )
                let targetTime = insertionTime(
                    for: chunk.capturedAt,
                    relativeTo: streamStart,
                    trustRoundedOffsets: true
                )
                    + startTime
                let timeRange = CMTimeRange(start: sourceTime, duration: chunkDuration)
                do {
                    try compositionTrack.insertTimeRange(timeRange, of: track, at: targetTime)
                } catch {
                    // Skip the chunk (leaves a gap) instead of aborting the export.
                    diagLog("[AUDIO] chunk insert failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
                sourceCursor += clampedDurationSeconds
            }
            return compositionTrack.trackID
        }

        if !validChunks.isEmpty {
            diagLog("[AUDIO] steady chunk timing detected for \(url.lastPathComponent), inserting contiguous track")
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionTrack.insertTimeRange(timeRange, of: track, at: startTime)
        return compositionTrack.trackID
    }

    // MARK: - Effective Sample Rate (OpenOats approach)

    /// Compute the actual sample rate by comparing total frames written to the
    /// wall-clock time span. If the effective rate differs significantly from the
    /// file's declared rate, we need to resample.
    private static func effectiveSampleRate(
        url: URL,
        chunks: [SessionAudioChunk]?,
        firstBufferAt: Date?
    ) -> Double? {
        let validChunks = SessionAudioTiming.validChunks(chunks)
        guard validChunks.count >= 2, let firstBufferAt else { return nil }

        // A session-average rate is only meaningful when the cadence is uniform.
        // If the stem contains MIXED rates (mid-session device or Bluetooth
        // profile switch), resampling the whole file at the average would corrupt
        // the correctly-rated portion too — defer to the per-chunk rebuilder.
        var snappedIntervalRates = Set<Double>()
        for index in 0..<(validChunks.count - 1) {
            let delta = validChunks[index + 1].capturedAt.timeIntervalSince(validChunks[index].capturedAt)
            guard delta > 0 else { continue }
            if let snapped = snapToCanonicalRate(Double(validChunks[index].frameCount) / delta) {
                snappedIntervalRates.insert(snapped)
            }
        }
        if snappedIntervalRates.count > 1 {
            diagLog(
                "[AUDIO-RATE-FIX] \(url.lastPathComponent): mixed interval rates " +
                "\(snappedIntervalRates.sorted()), deferring to chunk-aware rebuild"
            )
            return nil
        }

        let totalFrames = validChunks.reduce(0) { $0 + $1.frameCount }
        guard totalFrames > 0 else { return nil }

        let lastChunk = validChunks.last!
        let wallClockSeconds = lastChunk.capturedAt.timeIntervalSince(firstBufferAt)
        guard wallClockSeconds > 1.0 else { return nil }

        let effectiveRate = Double(totalFrames) / wallClockSeconds

        // Check if effective rate differs significantly from declared rate
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let declaredRate = audioFile.processingFormat.sampleRate
        let ratio = effectiveRate / declaredRate

        // If the effective rate is within 15% of declared, no correction needed
        if abs(ratio - 1.0) < 0.15 {
            return nil
        }

        diagLog(
            "[AUDIO-RATE-FIX] \(url.lastPathComponent): effective=\(Int(effectiveRate))Hz " +
            "declared=\(Int(declaredRate))Hz ratio=\(String(format: "%.2f", ratio))x " +
            "wallClock=\(String(format: "%.1f", wallClockSeconds))s"
        )
        return effectiveRate
    }

    /// Resample a CAF file from its effective sample rate to produce correct-duration
    /// output. Streams fixed-size blocks (re-tagged at the effective rate) through a
    /// persistent AVAudioConverter to 48kHz mono — whole-file buffers for a long
    /// session are multi-GB allocations that can kill the app during finalization.
    private static func resampleToCorrectDuration(
        sourceURL: URL,
        outputURL: URL,
        effectiveRate: Double
    ) throws -> URL? {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        let totalFrames = sourceFile.length
        guard totalFrames > 0 else { return nil }

        // Re-tag at the effective rate (same raw samples, different declared rate)
        guard let effectiveFormat = AVAudioFormat(
            commonFormat: sourceFormat.commonFormat,
            sampleRate: effectiveRate,
            channels: sourceFormat.channelCount,
            interleaved: sourceFormat.isInterleaved
        ) else { return nil }

        let targetRate: Double = 48_000
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetRate, channels: 1
        ) else { return nil }

        guard let converter = AVAudioConverter(from: effectiveFormat, to: targetFormat) else {
            return nil
        }

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )

        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let blockFrames: AVAudioFrameCount = 65_536
        let ratio = targetRate / effectiveRate
        var framesWritten: AVAudioFramePosition = 0

        while sourceFile.framePosition < totalFrames {
            guard let readBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: blockFrames
            ) else { return nil }
            try sourceFile.read(into: readBuffer, frameCount: blockFrames)
            guard readBuffer.frameLength > 0 else { break }

            guard let retaggedBuffer = AVAudioPCMBuffer(
                pcmFormat: effectiveFormat,
                frameCapacity: readBuffer.frameLength
            ) else { return nil }
            retaggedBuffer.frameLength = readBuffer.frameLength

            guard let src = readBuffer.floatChannelData,
                  let dst = retaggedBuffer.floatChannelData else { return nil }
            for ch in 0..<Int(sourceFormat.channelCount) {
                memcpy(dst[ch], src[ch], Int(readBuffer.frameLength) * MemoryLayout<Float>.size)
            }

            let outCapacity = AVAudioFrameCount(
                ceil(Double(retaggedBuffer.frameLength) * ratio) + 64
            )
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outCapacity
            ) else { return nil }

            var consumed = false
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return retaggedBuffer
            }
            if convError != nil { return nil }

            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
                framesWritten += AVAudioFramePosition(outBuffer.frameLength)
            }
        }

        // Drain the converter's held-back tail (.endOfStream) so the resampled
        // stem isn't short by the resampler's internal latency.
        if let tailBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) {
            var drainError: NSError?
            converter.convert(to: tailBuffer, error: &drainError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if drainError == nil, tailBuffer.frameLength > 0 {
                try outputFile.write(from: tailBuffer)
                framesWritten += AVAudioFramePosition(tailBuffer.frameLength)
            }
        }

        guard framesWritten > 0 else { return nil }
        succeeded = true

        let correctedDuration = Double(framesWritten) / targetRate
        diagLog(
            "[AUDIO-RATE-FIX] resampled \(sourceURL.lastPathComponent): " +
            "\(totalFrames) frames @ \(Int(effectiveRate))Hz -> " +
            "\(framesWritten) frames @ \(Int(targetRate))Hz " +
            "(duration: \(String(format: "%.1f", correctedDuration))s)"
        )

        return outputURL
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

    private static func snapToCanonicalRate(_ measuredRate: Double) -> Double? {
        guard measuredRate.isFinite,
              let nearestRate = canonicalRates.min(by: { abs($0 - measuredRate) < abs($1 - measuredRate) }) else {
            return nil
        }

        let tolerance = nearestRate * 0.05
        guard abs(nearestRate - measuredRate) <= tolerance else { return nil }
        return nearestRate
    }

    private static func insertionTime(
        for streamStart: Date?,
        relativeTo origin: Date?,
        trustRoundedOffsets: Bool
    ) -> CMTime {
        let offset = SessionAudioTiming.offsetSeconds(
            from: streamStart,
            relativeTo: origin,
            trustRoundedOffsets: trustRoundedOffsets
        )
        return CMTime(seconds: offset, preferredTimescale: 60_000)
    }
}
