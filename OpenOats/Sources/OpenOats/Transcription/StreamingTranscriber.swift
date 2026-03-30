@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via the TranscriptionBackend protocol.
final class StreamingTranscriber: @unchecked Sendable {
    private let backend: any TranscriptionBackend
    private let locale: Locale
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Flush interval in 16kHz samples. Determined by the transcription model.
    private let flushInterval: Int

    init(
        backend: any TranscriptionBackend,
        locale: Locale,
        vadManager: VadManager,
        speaker: Speaker,
        flushInterval: Int,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.backend = backend
        self.locale = locale
        self.vadManager = vadManager
        self.speaker = speaker
        self.flushInterval = flushInterval
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    /// Parakeet TDT requires >= 1s of audio; shorter segments produce unreliable output.
    private static let minimumSpeechSamples = 16_000
    private static let prerollChunkCount = 2
    // flushInterval is now an instance property, set per-model via TranscriptionModel.flushIntervalSamples
    /// Number of trailing words to carry across segment boundaries for decoder priming.
    private static let contextWordCount = 5

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
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
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] buffer #\(bufferCount, privacy: .public): frames=\(buffer.frameLength, privacy: .public) sr=\(fmt.sampleRate, privacy: .public) ch=\(fmt.channelCount, privacy: .public) interleaved=\(fmt.isInterleaved, privacy: .public) common=\(fmt.commonFormat.rawValue, privacy: .public)")
            }

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
                            await transcribeSegment(segment)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                            onPartial("")  // Clear partial display
                        }
                    } else if isSpeaking {

                        // Throttled partial hypothesis every ~400ms
                        if !isRunningPartial,
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
                            await transcribeSegment(segment)
                        }
                    }
                } catch {
                    Log.streaming.error("VAD error: \(error, privacy: .public)")
                }
            }
        }

        if speechSamples.count > Self.minimumSpeechSamples {
            onPartial("")  // Clear partial display
            await transcribeSegment(speechSamples)
        }
    }

    /// Trailing words from the last transcribed segment, used to prime the next segment's decoder.
    private var previousContext: String?

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let text = try await backend.transcribe(samples, locale: locale, previousContext: previousContext)
            guard !text.isEmpty else { return }
            Log.streaming.debug("[\(self.speaker.storageKey, privacy: .public)] transcribed: \(text.prefix(80), privacy: .private)")
            // Store trailing words for cross-segment context
            let words = text.split(separator: " ")
            previousContext = words.suffix(Self.contextWordCount).joined(separator: " ")
            onFinal(text)
        } catch {
            Log.streaming.error("ASR error: \(error, privacy: .public)")
        }
    }

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        // Fast path: already Float32 at 16kHz (common for system audio capture)
        if sourceFormat.commonFormat == .pcmFormatFloat32 && sourceFormat.sampleRate == 16000 {
            guard let channelData = buffer.floatChannelData else { return nil }
            if sourceFormat.channelCount == 1 {
                // Mono — direct copy
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else {
                // Multi-channel — take first channel only
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }
        }

        // Downmix multi-channel to mono before resampling
        // (AVAudioConverter mishandles deinterleaved multi-channel input)
        var inputBuffer = buffer
        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
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
