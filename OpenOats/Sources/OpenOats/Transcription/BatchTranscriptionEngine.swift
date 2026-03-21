@preconcurrency import AVFoundation
import FluidAudio
import os

private let batchLog = Logger(subsystem: "com.openoats.app", category: "BatchTranscription")

/// Offline two-pass transcription engine that processes recorded CAF files
/// using a higher-quality model after a meeting ends.
actor BatchTranscriptionEngine {

    enum Status: Sendable, Equatable {
        case idle
        case loading(model: String)
        case transcribing(progress: Double)
        case completed(sessionID: String)
        case cancelled
        case failed(String)
    }

    private(set) var status: Status = .idle
    private var currentTask: Task<Void, Never>?

    /// Process batch transcription for a completed session.
    func process(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionStore: SessionStore,
        notesDirectory: URL
    ) async {
        // Cancel any existing task
        currentTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runTranscription(
                    sessionID: sessionID,
                    model: model,
                    locale: locale,
                    sessionStore: sessionStore,
                    notesDirectory: notesDirectory
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                batchLog.info("Batch transcription cancelled for \(sessionID)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
                batchLog.error("Batch transcription failed: \(error.localizedDescription)")
            }
        }
        currentTask = task
        await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        status = .cancelled
    }

    // MARK: - Private

    private func setStatus(_ newStatus: Status) {
        status = newStatus
    }

    private func runTranscription(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionStore: SessionStore,
        notesDirectory: URL
    ) async throws {
        batchLog.info("Starting batch transcription for \(sessionID) with \(model.rawValue)")
        status = .loading(model: model.displayName)

        // Load batch metadata
        let urls = await sessionStore.batchAudioURLs(sessionID: sessionID)
        guard urls.mic != nil || urls.sys != nil else {
            batchLog.warning("No batch audio found for \(sessionID)")
            status = .failed("No audio files found")
            return
        }

        // Load timing anchors
        let anchors = await loadBatchMeta(sessionID: sessionID, sessionStore: sessionStore)

        // Create and prepare backend
        let backend = model.makeBackend()
        try await backend.prepare { statusMsg in
            batchLog.info("Backend: \(statusMsg)")
        }

        try Task.checkCancellation()

        // Load VAD
        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0)

        // Transcribe each audio file
        var micRecords: [SessionRecord] = []
        var sysRecords: [SessionRecord] = []

        let totalFiles = (urls.mic != nil ? 1 : 0) + (urls.sys != nil ? 1 : 0)
        var filesProcessed = 0

        if let micURL = urls.mic {
            micRecords = try await transcribeFile(
                url: micURL,
                speaker: .you,
                startDate: anchors?.micStartDate,
                sampleRate: anchors?.micSampleRate,
                backend: backend,
                vad: vad,
                locale: locale,
                progressBase: 0,
                progressScale: 1.0 / Double(totalFiles)
            )
            filesProcessed += 1
            batchLog.info("Mic transcription: \(micRecords.count) records")
        }

        try Task.checkCancellation()

        if let sysURL = urls.sys {
            sysRecords = try await transcribeFile(
                url: sysURL,
                speaker: .them,
                startDate: anchors?.sysStartDate,
                sampleRate: anchors?.sysSampleRate,
                backend: backend,
                vad: vad,
                locale: locale,
                progressBase: Double(filesProcessed) / Double(totalFiles),
                progressScale: 1.0 / Double(totalFiles)
            )
            batchLog.info("Sys transcription: \(sysRecords.count) records")
        }

        try Task.checkCancellation()

        // Apply echo suppression
        AcousticEchoFilter.suppress(micRecords: &micRecords, against: sysRecords)

        // Interleave by timestamp
        var allRecords = micRecords + sysRecords
        allRecords.sort { $0.timestamp < $1.timestamp }

        guard !allRecords.isEmpty else {
            batchLog.warning("Batch transcription produced no records for \(sessionID)")
            await sessionStore.cleanupBatchAudio(sessionID: sessionID)
            status = .completed(sessionID: sessionID)
            return
        }

        // Atomic write
        await sessionStore.writeBatchTranscript(sessionID: sessionID, records: allRecords)

        // Update the Markdown file with the refined transcript
        patchMarkdownTranscript(
            sessionID: sessionID,
            records: allRecords,
            notesDirectory: notesDirectory,
            sessionStore: sessionStore
        )

        // Cleanup audio files
        await sessionStore.cleanupBatchAudio(sessionID: sessionID)

        status = .completed(sessionID: sessionID)
        batchLog.info("Batch transcription completed for \(sessionID): \(allRecords.count) records")
    }

    // MARK: - File Transcription

    private func transcribeFile(
        url: URL,
        speaker: Speaker,
        startDate: Date?,
        sampleRate: Double?,
        backend: any TranscriptionBackend,
        vad: VadManager,
        locale: Locale,
        progressBase: Double,
        progressScale: Double
    ) async throws -> [SessionRecord] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            batchLog.warning("Cannot open audio file: \(url.lastPathComponent)")
            return []
        }

        let fileSampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        guard totalFrames > 0 else { return [] }

        let resolvedStartDate = startDate ?? Date()
        let resolvedSampleRate = sampleRate ?? fileSampleRate

        // Process in 30-second chunks
        let chunkFrames = Int64(30.0 * fileSampleRate)
        var records: [SessionRecord] = []
        var frameOffset: Int64 = 0

        while frameOffset < totalFrames {
            try Task.checkCancellation()

            let framesToRead = min(chunkFrames, totalFrames - frameOffset)
            let chunk = try readChunk(
                file: audioFile,
                startFrame: frameOffset,
                frameCount: AVAudioFrameCount(framesToRead)
            )

            guard !chunk.isEmpty else {
                frameOffset += framesToRead
                continue
            }

            // Run VAD on the chunk to find speech segments
            let speechSegments = try await detectSpeech(samples: chunk, vad: vad)

            for segment in speechSegments {
                try Task.checkCancellation()

                // Context padding: if segment is short, pad to ~30s
                let targetSamples = 30 * 16000
                var transcriptionSamples = segment.samples
                if transcriptionSamples.count < targetSamples {
                    // Use surrounding audio for context
                    let sampleOffset = segment.startSample
                    let globalOffset = Int(frameOffset * 16000 / Int64(fileSampleRate)) + sampleOffset
                    let padBefore = min(globalOffset, (targetSamples - transcriptionSamples.count) / 2)

                    // For simplicity, just transcribe the segment as-is
                    // The model handles short segments fine
                    _ = padBefore
                }

                let text = try await backend.transcribe(transcriptionSamples, locale: locale)
                guard !text.isEmpty else { continue }

                // Calculate timestamp from frame position
                let sampleOffsetInFile = Double(frameOffset) + Double(segment.startSample) * fileSampleRate / 16000.0
                let timeOffset = sampleOffsetInFile / resolvedSampleRate
                let timestamp = resolvedStartDate.addingTimeInterval(timeOffset)

                records.append(SessionRecord(
                    speaker: speaker,
                    text: text,
                    timestamp: timestamp
                ))
            }

            frameOffset += framesToRead

            // Update progress
            let fileProgress = Double(frameOffset) / Double(totalFrames)
            status = .transcribing(progress: progressBase + fileProgress * progressScale)
        }

        return records
    }

    // MARK: - Audio Reading

    /// Read a chunk from an AVAudioFile and resample to 16kHz mono Float32.
    private func readChunk(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: AVAudioFrameCount
    ) throws -> [Float] {
        let srcFormat = file.processingFormat
        file.framePosition = startFrame

        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: readBuf)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Fast path: already at target format
        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            guard let data = readBuf.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(readBuf.frameLength)))
        }

        // Downmix to mono first if needed
        var inputBuffer = readBuf
        if srcFormat.channelCount > 1, let src = readBuf.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: readBuf.frameCapacity),
               let dst = monoBuf.floatChannelData?[0] {
                monoBuf.frameLength = readBuf.frameLength
                let channels = Int(srcFormat.channelCount)
                let scale = 1.0 / Float(channels)
                for i in 0..<Int(readBuf.frameLength) {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[i] = sum * scale
                }
                inputBuffer = monoBuf
            }
        }

        // Resample via AVAudioConverter
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
            // If conversion not possible, try direct extraction
            guard let data = inputBuffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(inputBuffer.frameLength)))
        }

        let ratio = 16000.0 / inputBuffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return []
        }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputRef = inputBuffer
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputRef
        }

        guard let data = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength)))
    }

    // MARK: - VAD

    private struct SpeechSegment {
        let startSample: Int
        let samples: [Float]
    }

    /// Detect speech segments in a chunk of 16kHz mono audio using Silero VAD.
    private func detectSpeech(samples: [Float], vad: VadManager) async throws -> [SpeechSegment] {
        let vadChunkSize = 4096
        let minimumSpeechSamples = 8000

        var vadState = await vad.makeStreamState()
        var segments: [SpeechSegment] = []
        var speechBuffer: [Float] = []
        var speechStart: Int?
        var offset = 0

        while offset + vadChunkSize <= samples.count {
            try Task.checkCancellation()

            let chunk = Array(samples[offset..<(offset + vadChunkSize)])

            let result = try await vad.processStreamingChunk(
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
                    if speechStart == nil {
                        speechStart = offset
                        speechBuffer = []
                    }
                case .speechEnd:
                    if speechStart != nil {
                        speechBuffer.append(contentsOf: chunk)
                        if speechBuffer.count >= minimumSpeechSamples {
                            segments.append(SpeechSegment(
                                startSample: speechStart!,
                                samples: speechBuffer
                            ))
                        }
                        speechStart = nil
                        speechBuffer = []
                    }
                }
            }

            if speechStart != nil {
                speechBuffer.append(contentsOf: chunk)
            }

            offset += vadChunkSize
        }

        // Flush remaining speech
        if let start = speechStart, speechBuffer.count >= minimumSpeechSamples {
            segments.append(SpeechSegment(startSample: start, samples: speechBuffer))
        }

        return segments
    }

    // MARK: - Batch Meta

    private struct ResolvedAnchors {
        let micStartDate: Date?
        let sysStartDate: Date?
        let micSampleRate: Double?
        let sysSampleRate: Double?
    }

    private func loadBatchMeta(
        sessionID: String,
        sessionStore: SessionStore
    ) async -> ResolvedAnchors? {
        guard let meta = await sessionStore.loadBatchMeta(sessionID: sessionID) else {
            return nil
        }

        return ResolvedAnchors(
            micStartDate: meta.micStartDate,
            sysStartDate: meta.sysStartDate,
            micSampleRate: nil,
            sysSampleRate: nil
        )
    }

    // MARK: - Markdown Patching

    private nonisolated func patchMarkdownTranscript(
        sessionID: String,
        records: [SessionRecord],
        notesDirectory: URL,
        sessionStore: SessionStore
    ) {
        guard let fileURL = MarkdownMeetingWriter.findMarkdownFile(
            sessionID: sessionID,
            in: notesDirectory
        ) else {
            batchLog.info("No markdown file found for \(sessionID), skipping patch")
            return
        }

        MarkdownMeetingWriter.patchTranscriptSection(
            fileURL: fileURL,
            records: records
        )
    }
}

// MARK: - JSONDecoder Extension

extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
