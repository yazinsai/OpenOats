@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via the TranscriptionBackend protocol.
final class StreamingTranscriber: @unchecked Sendable {
    struct CloudSegmentStatus: Sendable, Equatable {
        enum Kind: String, Sendable, Equatable {
            case success
            case empty
            case error
        }

        let kind: Kind
        let presentation: CloudTranscriptCopy.Presentation?
    }

    struct CloudSegmentDiagnosticsEvent: Codable, Equatable {
        let event: String
        let sessionID: String?
        let transcriptionModel: String
        let backend: String
        let speaker: String
        let sampleCount: Int
        let durationSeconds: Double
        let elapsedMilliseconds: Int
        let result: String
        let textLength: Int?
        let errorKind: String?
        let errorMessage: String?
    }

    private let backend: any TranscriptionBackend
    private let locale: Locale
    private let vadManager: VadManager
    private let speaker: Speaker
    private let sessionID: String?
    private let transcriptionModel: String
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let onCloudSegmentStatus: (@Sendable (CloudSegmentStatus) -> Void)?
    private let onCloudProcessingChanged: (@Sendable (Bool) -> Void)?

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // -- Effective sample rate correction --
    // Core Audio process taps can declare one sample rate but deliver audio at a
    // different rate.  AudioRecorder already compensates for this when writing the
    // merged file, but the streaming transcriber was trusting the declared rate,
    // causing incorrect resampling and garbled audio for VAD + ASR.
    //
    // We measure the *actual* rate by comparing wall-clock time to frames received.
    // Once we have ≥ 3 s of data and the rates diverge by > 5 %, we lock in the
    // effective rate and rebuild the converter.
    private var rateTrackingStartDate: Date?
    private var rateTrackingTotalFrames: Int64 = 0
    private var effectiveSampleRate: Double?
    /// Minimum wall-clock seconds before we trust the effective rate measurement.
    private static let rateWarmupSeconds: Double = 3.0
    /// Relative threshold: if effective rate differs by more than this fraction, correct it.
    private static let rateDivergenceThreshold: Double = 0.05

    /// Flush interval in 16kHz samples. Determined by the transcription model.
    private let flushInterval: Int

    /// When true, skip inline partial hypotheses to avoid blocking the VAD loop.
    /// Cloud backends (AssemblyAI, ElevenLabs) are too slow for partial transcription
    /// because each call involves an HTTP upload + polling cycle that stalls audio processing.
    private let skipPartials: Bool

    init(
        backend: any TranscriptionBackend,
        locale: Locale,
        vadManager: VadManager,
        speaker: Speaker,
        sessionID: String?,
        transcriptionModel: String,
        flushInterval: Int,
        skipPartials: Bool = false,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
        onCloudSegmentStatus: (@Sendable (CloudSegmentStatus) -> Void)? = nil,
        onCloudProcessingChanged: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.backend = backend
        self.locale = locale
        self.vadManager = vadManager
        self.speaker = speaker
        self.sessionID = sessionID
        self.transcriptionModel = transcriptionModel
        self.flushInterval = flushInterval
        self.skipPartials = skipPartials
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onCloudSegmentStatus = onCloudSegmentStatus
        self.onCloudProcessingChanged = onCloudProcessingChanged
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Parakeet TDT requires >= 1s of audio; shorter segments produce unreliable output.
    private static let minimumSpeechSamples = 16_000
    private static let prerollChunkCount = 2
    // flushInterval is now an instance property, set per-model via TranscriptionModel.flushIntervalSamples
    /// Number of trailing words to carry across segment boundaries for decoder priming.
    private static let contextWordCount = 5
    private static let cloudSegmentDiagnosticsEventName = "live_cloud_segment_transcription"

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        let segmentQueue = makeSegmentQueueIfNeeded()
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var vadReadIndex = 0
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var bufferCount = 0
        var lastPartialTime: Date = .distantPast
        var isRunningPartial = false

        for await buffer in stream {
            guard !Task.isCancelled else { break }
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] buffer #\(bufferCount, privacy: .public): frames=\(buffer.frameLength, privacy: .public) sr=\(fmt.sampleRate, privacy: .public) ch=\(fmt.channelCount, privacy: .public) interleaved=\(fmt.isInterleaved, privacy: .public) common=\(fmt.commonFormat.rawValue, privacy: .public)")
            }

            // Track effective sample rate (detects process-tap rate mismatch)
            updateRateTracking(buffer)

            guard let samples = extractSamples(buffer) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] samples: count=\(samples.count, privacy: .public) max=\(maxVal, privacy: .public)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count - vadReadIndex >= Self.vadChunkSize {
                let chunk = Array(vadBuffer[vadReadIndex..<(vadReadIndex + Self.vadChunkSize)])
                vadReadIndex += Self.vadChunkSize

                // Compact when we've consumed more than half to bound memory growth
                if vadReadIndex > vadBuffer.count / 2 {
                    vadBuffer.removeFirst(vadReadIndex)
                    vadReadIndex = 0
                }
                let wasSpeaking = isSpeaking

                var startedSpeech = false
                var endedSpeech = false
                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                                Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] speech start")
                            }

                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
                        }
                    }

                    if wasSpeaking || startedSpeech || endedSpeech {
                        speechSamples.append(contentsOf: chunk)
                        recentChunks.removeAll(keepingCapacity: true)
                    } else {
                        recentChunks.append(chunk)
                        if recentChunks.count > Self.prerollChunkCount {
                            recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                        }
                    }

                    if endedSpeech {
                        isSpeaking = false
                        isRunningPartial = false
                        Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] speech end, samples=\(speechSamples.count, privacy: .public)")
                        if speechSamples.count > Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            onPartial("")  // Clear partial display
                            await submitSegment(segment, using: segmentQueue)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                            onPartial("")  // Clear partial display
                        }
                    } else if isSpeaking {

                        // Throttled partial hypothesis every ~400ms.
                        // Skipped for cloud backends — each call blocks the VAD loop
                        // for seconds while the HTTP round-trip completes.
                        if !skipPartials,
                           !isRunningPartial,
                           speechSamples.count > Self.minimumSpeechSamples,
                           Date.now.timeIntervalSince(lastPartialTime) >= 0.4 {
                            isRunningPartial = true
                            lastPartialTime = .now
                            let snapshot = speechSamples
                            do {
                                let text = try await backend.transcribe(snapshot, locale: locale, previousContext: nil)
                                if !text.isEmpty && !Task.isCancelled {
                                    onPartial(text)
                                }
                            } catch {
                                // Best-effort — ignore
                            }
                            isRunningPartial = false
                        }

                        // Flush on long continuous speech (see flushInterval)
                        if speechSamples.count >= flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            onPartial("")  // Clear partial display
                            await submitSegment(segment, using: segmentQueue)
                        }
                    }
                } catch {
                    Log.streaming.error("VAD error: \(error, privacy: .public)")
                }
            }
        }

        if speechSamples.count > Self.minimumSpeechSamples {
            onPartial("")  // Clear partial display
            await submitSegment(speechSamples, using: segmentQueue)
        }

        if let segmentQueue {
            if Task.isCancelled {
                await segmentQueue.cancel()
            } else {
                await segmentQueue.finish()
            }
        }
    }

    /// Trailing words from the last transcribed segment, used to prime the next segment's decoder.
    private var previousContext: String?

    private func makeSegmentQueueIfNeeded() -> StreamingTranscriptionSegmentQueue? {
        guard skipPartials else { return nil }
        return StreamingTranscriptionSegmentQueue(
            onProcessingChanged: onCloudProcessingChanged
        ) { [self] segment in
            await transcribeSegment(segment)
        }
    }

    private func submitSegment(
        _ samples: [Float],
        using queue: StreamingTranscriptionSegmentQueue?
    ) async {
        if let queue {
            await queue.enqueue(samples)
        } else {
            await transcribeSegment(samples)
        }
    }

    private func transcribeSegment(_ samples: [Float]) async {
        let startedAt = Date()
        do {
            try Task.checkCancellation()
            let text = try await backend.transcribe(samples, locale: locale, previousContext: previousContext)
            if text.isEmpty {
                onCloudSegmentStatus?(
                    CloudSegmentStatus(
                        kind: .empty,
                        presentation: CloudTranscriptCopy.emptyChunk
                    )
                )
                recordCloudSegmentDiagnostics(
                    samples: samples,
                    startedAt: startedAt,
                    result: "empty",
                    textLength: 0,
                    errorKind: nil,
                    errorMessage: nil
                )
                Log.streaming.warning(
                    "[\(self.speaker.storageKey, privacy: .public)] cloud segment returned empty text: backend=\(self.backend.displayName, privacy: .public) duration=\(String(format: "%.2f", Double(samples.count) / 16_000), privacy: .public)s"
                )
                return
            }
            Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] transcribed: \(text.prefix(80), privacy: .private)")
            onCloudSegmentStatus?(CloudSegmentStatus(kind: .success, presentation: nil))
            recordCloudSegmentDiagnostics(
                samples: samples,
                startedAt: startedAt,
                result: "success",
                textLength: text.count,
                errorKind: nil,
                errorMessage: nil
            )
            // Store trailing words for cross-segment context
            let words = text.split(separator: " ")
            previousContext = words.suffix(Self.contextWordCount).joined(separator: " ")
            onFinal(text)
        } catch {
            onCloudSegmentStatus?(CloudSegmentStatus(kind: .error, presentation: CloudTranscriptCopy.presentation(for: error)))
            recordCloudSegmentDiagnostics(
                samples: samples,
                startedAt: startedAt,
                result: "error",
                textLength: nil,
                errorKind: Self.cloudDiagnosticsErrorKind(for: error),
                errorMessage: Self.cloudDiagnosticsErrorMessage(for: error)
            )
            Log.streaming.error("ASR error: \(error, privacy: .public)")
        }
    }

    private func recordCloudSegmentDiagnostics(
        samples: [Float],
        startedAt: Date,
        result: String,
        textLength: Int?,
        errorKind: String?,
        errorMessage: String?
    ) {
        guard skipPartials else { return }

        let elapsedMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        let event = CloudSegmentDiagnosticsEvent(
            event: Self.cloudSegmentDiagnosticsEventName,
            sessionID: sessionID,
            transcriptionModel: transcriptionModel,
            backend: backend.displayName,
            speaker: speaker.storageKey,
            sampleCount: samples.count,
            durationSeconds: Double(samples.count) / 16_000,
            elapsedMilliseconds: elapsedMilliseconds,
            result: result,
            textLength: textLength,
            errorKind: errorKind,
            errorMessage: errorMessage
        )
        DiagnosticsSupport.record(
            category: "transcription",
            message: Self.cloudSegmentDiagnosticsMessage(for: event)
        )
    }

    static func cloudSegmentDiagnosticsMessage(for event: CloudSegmentDiagnosticsEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(event),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{\"event\":\"\(Self.cloudSegmentDiagnosticsEventName)\",\"result\":\"encoding_failed\"}"
    }

    static func cloudDiagnosticsErrorKind(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let cloudError = error as? CloudASRError {
            switch cloudError {
            case .invalidAPIKey:
                return "invalid_api_key"
            case .invalidUploadURL:
                return "invalid_upload_url"
            case .httpError(let statusCode):
                return "http_\(statusCode)"
            case .transcriptionFailed:
                return "transcription_failed"
            case .timeout:
                return "timeout"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "transport_timeout"
            case .networkConnectionLost:
                return "transport_connection_lost"
            default:
                return "url_\(urlError.code.rawValue)"
            }
        }
        return "other"
    }

    static func cloudDiagnosticsErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return String(describing: error) }
        return String(message.prefix(200))
    }

    /// Track wall-clock time vs frames received to detect process-tap rate mismatch.
    private func updateRateTracking(_ buffer: AVAudioPCMBuffer) {
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }

        let now = Date()
        if rateTrackingStartDate == nil {
            rateTrackingStartDate = now
        }
        rateTrackingTotalFrames += frames

        // Only compute after warmup period; skip if already locked in
        guard effectiveSampleRate == nil,
              let start = rateTrackingStartDate else { return }

        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= Self.rateWarmupSeconds else { return }

        let measured = Double(rateTrackingTotalFrames) / elapsed
        let declared = buffer.format.sampleRate
        let divergence = abs(measured - declared) / declared

        if divergence > Self.rateDivergenceThreshold {
            effectiveSampleRate = measured
            converter = nil // force rebuild on next extractSamples call
            Log.streaming.warning("[\(self.speaker.storageKey, privacy: .public)] rate mismatch: declared=\(declared, privacy: .public) effective=\(measured, privacy: .public) (divergence \(String(format: "%.1f", divergence * 100), privacy: .public)%), correcting resampler")
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Determine the actual sample rate (may differ from declared for process taps)
        let actualRate = effectiveSampleRate ?? sourceFormat.sampleRate

        // Fast path: already Float32 at 16kHz
        if sourceFormat.commonFormat == .pcmFormatFloat32 && actualRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else {
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }
        }

        // Downmix multi-channel to mono before resampling
        // (AVAudioConverter mishandles deinterleaved multi-channel input)
        var inputBuffer = buffer
        let monoRate = actualRate
        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: monoRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
               let dst = monoBuf.floatChannelData?[0] {
                monoBuf.frameLength = buffer.frameLength
                let channels = Int(sourceFormat.channelCount)
                let scale = 1.0 / Float(channels)
                for i in 0..<frameLength {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[i] = sum * scale
                }
                inputBuffer = monoBuf
            }
        } else if effectiveSampleRate != nil, sourceFormat.channelCount == 1 {
            // Mono but rate-corrected: re-wrap buffer with the effective rate so the
            // converter uses the correct ratio.
            let correctedFormat = AVAudioFormat(
                commonFormat: sourceFormat.commonFormat,
                sampleRate: monoRate,
                channels: 1,
                interleaved: sourceFormat.isInterleaved
            )!
            if let rewrapped = AVAudioPCMBuffer(pcmFormat: correctedFormat, frameCapacity: buffer.frameCapacity) {
                rewrapped.frameLength = buffer.frameLength
                if let srcData = buffer.floatChannelData?[0],
                   let dstData = rewrapped.floatChannelData?[0] {
                    memcpy(dstData, srcData, frameLength * MemoryLayout<Float>.size)
                    inputBuffer = rewrapped
                }
            }
        }

        // Slow path: need to resample via AVAudioConverter
        let inputFormat = inputBuffer.format
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard outputFrames > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            Log.streaming.error("Resample error: \(error, privacy: .public)")
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
