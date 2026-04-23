@preconcurrency import AVFoundation
import FluidAudio

struct BatchTranscriptOverwriteGuard {
    private struct TranscriptStats {
        let recordCount: Int
        let nonWhitespaceCharacterCount: Int
        let duration: TimeInterval

        init(records: [SessionRecord]) {
            recordCount = records.count
            nonWhitespaceCharacterCount = records.reduce(into: 0) { total, record in
                let text = record.cleanedText ?? record.text
                total += text.unicodeScalars.reduce(into: 0) { count, scalar in
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        count += 1
                    }
                }
            }
            if let first = records.first?.timestamp, let last = records.last?.timestamp {
                duration = max(0, last.timeIntervalSince(first))
            } else {
                duration = 0
            }
        }

        var isSubstantial: Bool {
            recordCount >= 4 || nonWhitespaceCharacterCount >= 120
        }
    }

    static func rejectionReason(
        existingRecords: [SessionRecord],
        replacementRecords: [SessionRecord]
    ) -> String? {
        let existing = TranscriptStats(records: existingRecords)
        guard existing.isSubstantial else { return nil }

        let replacement = TranscriptStats(records: replacementRecords)
        let characterCollapseThreshold = max(40, Int(Double(existing.nonWhitespaceCharacterCount) * 0.35))
        let characterCollapse = replacement.nonWhitespaceCharacterCount < characterCollapseThreshold
        let recordCollapse = replacement.recordCount * 3 < existing.recordCount
        let durationCollapse = existing.duration >= 60 && replacement.duration < existing.duration * 0.4

        guard characterCollapse && (recordCollapse || durationCollapse) else {
            return nil
        }

        return "Batch re-transcription looks unreliable; kept existing transcript"
    }
}

/// Offline two-pass transcription engine that processes recorded CAF files
/// using a higher-quality model after a meeting ends.
actor BatchAudioTranscriber {

    enum Status: Sendable, Equatable {
        case idle
        case loading(model: String)
        case transcribing(progress: Double)
        case completed(sessionID: String)
        case cancelled
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// True when the current batch job is an audio file import (affects UI copy).
    private(set) var isImporting: Bool = false
    private var currentTask: Task<Void, Never>?

    /// Process batch transcription for a completed session.
    func process(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository,
        notesDirectory: URL,
        enableDiarization: Bool = false,
        diarizationVariant: DiarizationVariant = .dihard3
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
                    sessionRepository: sessionRepository,
                    notesDirectory: notesDirectory,
                    enableDiarization: enableDiarization,
                    diarizationVariant: diarizationVariant
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription cancelled for \(sessionID)")
                Log.batchTranscription.info("Batch transcription cancelled for \(sessionID, privacy: .public)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription failed for \(sessionID): \(error.localizedDescription)")
                Log.batchTranscription.error("Batch transcription failed: \(error, privacy: .public)")
            }
        }
        currentTask = task
        await task.value
    }

    func cancel() async {
        let task = currentTask
        currentTask = nil
        task?.cancel()
        await task?.value
        status = .cancelled
        isImporting = false
    }

    // MARK: - Audio Import

    /// Import and transcribe an external audio file (meeting recording).
    func importFile(
        url: URL,
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository
    ) async {
        currentTask?.cancel()
        isImporting = true

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runImport(
                    url: url,
                    sessionID: sessionID,
                    model: model,
                    locale: locale,
                    sessionRepository: sessionRepository
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                await self.setIsImporting(false)
                DiagnosticsSupport.record(category: "batch", message: "Audio import cancelled for \(sessionID)")
                Log.batchTranscription.info("Audio import cancelled for \(sessionID, privacy: .public)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription))
                await self.setIsImporting(false)
                DiagnosticsSupport.record(category: "batch", message: "Audio import failed for \(sessionID): \(error.localizedDescription)")
                Log.batchTranscription.error("Audio import failed: \(error, privacy: .public)")
            }
        }
        currentTask = task
        await task.value
    }

    private func runImport(
        url: URL,
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository
    ) async throws {
        Log.batchTranscription.info("Starting audio import for \(sessionID, privacy: .public) from \(url.lastPathComponent, privacy: .public)")
        DiagnosticsSupport.record(category: "batch", message: "Starting audio import for \(sessionID) model=\(model.rawValue)")
        status = .loading(model: model.displayName)

        // Prepare backend and VAD
        let backend = model.makeBackend()
        try await backend.prepare { statusMsg in
            Log.batchTranscription.debug("Backend: \(statusMsg, privacy: .public)")
        }

        try Task.checkCancellation()

        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0)

        // Derive start date from file attributes
        let startDate: Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attrs[.creationDate] as? Date {
            startDate = creationDate
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date {
            startDate = modDate
        } else {
            startDate = Date()
        }

        // Transcribe the file as a single speaker
        let records = try await transcribeFile(
            url: url,
            speaker: .them,
            startDate: startDate,
            sampleRate: nil,
            backend: backend,
            vad: vad,
            locale: locale,
            progressBase: 0,
            progressScale: 1.0
        )

        try Task.checkCancellation()

        guard !records.isEmpty else {
            Log.batchTranscription.warning("Audio import produced no records for \(sessionID, privacy: .public)")
            DiagnosticsSupport.record(category: "batch", message: "Audio import produced no speech for \(sessionID)")
            status = .failed("No speech detected in the audio file")
            isImporting = false
            return
        }

        // Derive endedAt from last record timestamp
        let endedAt = records.last?.timestamp ?? startDate

        // Save final transcript atomically
        await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: records)

        // Update session metadata with final counts
        await sessionRepository.finalizeImportedSession(
            sessionID: sessionID,
            utteranceCount: records.count,
            endedAt: endedAt
        )

        // Copy original audio file to session
        await sessionRepository.copyAudioFileToSession(sessionID: sessionID, sourceURL: url)

        status = .completed(sessionID: sessionID)
        isImporting = false
        DiagnosticsSupport.record(category: "batch", message: "Audio import completed for \(sessionID) records=\(records.count)")
        Log.batchTranscription.info("Audio import completed for \(sessionID, privacy: .public): \(records.count, privacy: .public) records")
    }

    // MARK: - Private

    private func setStatus(_ newStatus: Status) {
        status = newStatus
    }

    private func setIsImporting(_ value: Bool) {
        isImporting = value
    }

    private func runTranscription(
        sessionID: String,
        model: TranscriptionModel,
        locale: Locale,
        sessionRepository: SessionRepository,
        notesDirectory: URL,
        enableDiarization: Bool,
        diarizationVariant: DiarizationVariant
    ) async throws {
        Log.batchTranscription.info("Starting batch transcription for \(sessionID, privacy: .public) with \(model.rawValue, privacy: .public)")
        DiagnosticsSupport.record(category: "batch", message: "Starting batch transcription for \(sessionID) model=\(model.rawValue)")
        status = .loading(model: model.displayName)

        // Load batch metadata
        let urls = await sessionRepository.batchAudioURLs(sessionID: sessionID)
        guard urls.mic != nil || urls.sys != nil else {
            Log.batchTranscription.warning("No batch audio found for \(sessionID, privacy: .public)")
            DiagnosticsSupport.record(category: "batch", message: "No retained batch audio found for \(sessionID)")
            status = .failed("No audio files found")
            return
        }

        // Load timing anchors
        let anchors = await loadBatchMeta(sessionID: sessionID, sessionRepository: sessionRepository)

        // Create and prepare backend
        let backend = model.makeBackend()
        try await backend.prepare { statusMsg in
            Log.batchTranscription.debug("Backend: \(statusMsg, privacy: .public)")
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
            Log.batchTranscription.debug("Mic transcription: \(micRecords.count, privacy: .public) records")
        }

        try Task.checkCancellation()

        if let sysURL = urls.sys {
            // Optionally run diarization on the full system audio
            var batchDiarizer: DiarizationManager?
            if enableDiarization {
                Log.batchTranscription.info("Running LS-EEND diarization on system audio...")
                let dm = DiarizationManager()
                let variant = LSEENDVariant(rawValue: diarizationVariant.rawValue) ?? .dihard3
                try await dm.load(variant: variant)
                // Process complete audio file through diarizer
                let samples = try BatchAudioSampleReader.readAll(
                    url: sysURL,
                    targetRate: 16000,
                    overrideSampleRate: anchors?.sysSampleRate
                )
                try await dm.feedAudio(samples)
                await dm.finalize()
                batchDiarizer = dm
                Log.batchTranscription.info("Diarization complete")
            }

            sysRecords = try await transcribeFile(
                url: sysURL,
                speaker: .them,
                startDate: anchors?.sysStartDate,
                sampleRate: anchors?.sysSampleRate,
                backend: backend,
                vad: vad,
                locale: locale,
                progressBase: Double(filesProcessed) / Double(totalFiles),
                progressScale: 1.0 / Double(totalFiles),
                diarizationManager: batchDiarizer
            )
            Log.batchTranscription.debug("Sys transcription: \(sysRecords.count, privacy: .public) records")
        }

        try Task.checkCancellation()

        // Apply echo suppression
        AcousticEchoFilter.suppress(micRecords: &micRecords, against: sysRecords)

        // Interleave by timestamp
        var allRecords = micRecords + sysRecords
        allRecords.sort { $0.timestamp < $1.timestamp }
        let existingRecords = await sessionRepository.loadTranscript(sessionID: sessionID)

        guard !allRecords.isEmpty else {
            Log.batchTranscription.warning("Batch transcription produced no records for \(sessionID, privacy: .public)")
            if existingRecords.isEmpty {
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription produced no speech for \(sessionID)")
                status = .failed("Batch re-transcription produced no speech")
            } else {
                DiagnosticsSupport.record(category: "batch", message: "Batch transcription produced no speech for \(sessionID); kept existing transcript")
                status = .failed("Batch re-transcription produced no speech; kept existing transcript")
            }
            return
        }

        if let rejectionReason = BatchTranscriptOverwriteGuard.rejectionReason(
            existingRecords: existingRecords,
            replacementRecords: allRecords
        ) {
            Log.batchTranscription.warning(
                "Skipping batch transcript overwrite for \(sessionID, privacy: .public): \(rejectionReason, privacy: .public)"
            )
            DiagnosticsSupport.record(category: "batch", message: "Rejected batch overwrite for \(sessionID): \(rejectionReason)")
            status = .failed(rejectionReason)
            return
        }

        // Atomic write of final transcript + full markdown regeneration via mirroring
        await sessionRepository.saveFinalTranscript(
            sessionID: sessionID,
            records: allRecords,
            backupCurrentTranscript: true
        )
        // Retain batch stems/metadata for a bounded rerun/debug window.
        // SessionRepository purges expired retained assets on startup.

        status = .completed(sessionID: sessionID)
        DiagnosticsSupport.record(category: "batch", message: "Batch transcription completed for \(sessionID) records=\(allRecords.count)")
        Log.batchTranscription.info("Batch transcription completed for \(sessionID, privacy: .public): \(allRecords.count, privacy: .public) records")
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
        progressScale: Double,
        diarizationManager: DiarizationManager? = nil
    ) async throws -> [SessionRecord] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            Log.batchTranscription.warning("Cannot open audio file: \(url.lastPathComponent, privacy: .public)")
            return []
        }

        let fileSampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        guard totalFrames > 0 else { return [] }

        let resolvedStartDate = startDate ?? Date()
        let resolvedSampleRate = sampleRate ?? fileSampleRate

        // Process in 30-second chunks
        let chunkFrames = Int64(30.0 * resolvedSampleRate)
        var records: [SessionRecord] = []
        var frameOffset: Int64 = 0

        while frameOffset < totalFrames {
            try Task.checkCancellation()

            let framesToRead = min(chunkFrames, totalFrames - frameOffset)
            let chunk = try readChunk(
                file: audioFile,
                startFrame: frameOffset,
                frameCount: AVAudioFrameCount(framesToRead),
                overrideSampleRate: sampleRate
            )

            guard !chunk.isEmpty else {
                frameOffset += framesToRead
                continue
            }

            // Run VAD on the chunk to find speech segments
            let speechSegments = try await detectSpeech(samples: chunk, vad: vad)

            for segment in speechSegments {
                try Task.checkCancellation()

                let text = try await backend.transcribe(segment.samples, locale: locale, previousContext: nil)
                guard !text.isEmpty else { continue }

                // Calculate timestamp from frame position
                let sampleOffsetInFile = Double(frameOffset) + Double(segment.startSample) * resolvedSampleRate / 16000.0
                let timeOffset = sampleOffsetInFile / resolvedSampleRate
                let timestamp = resolvedStartDate.addingTimeInterval(timeOffset)

                // Resolve speaker from diarizer if available
                let resolvedSpeaker: Speaker
                if let dm = diarizationManager {
                    let endSample = segment.startSample + segment.samples.count
                    let segEndOffset = Double(frameOffset) + Double(endSample) * resolvedSampleRate / 16000.0
                    let segEndTime = segEndOffset / resolvedSampleRate
                    resolvedSpeaker = await dm.dominantSpeaker(from: timeOffset, to: segEndTime)
                } else {
                    resolvedSpeaker = speaker
                }

                records.append(SessionRecord(
                    speaker: resolvedSpeaker,
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
        frameCount: AVAudioFrameCount,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        file.framePosition = startFrame
        return try BatchAudioSampleReader.readChunk(
            from: file,
            frameCount: frameCount,
            targetRate: 16000,
            overrideSampleRate: overrideSampleRate
        )
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
        sessionRepository: SessionRepository
    ) async -> ResolvedAnchors? {
        guard let meta = await sessionRepository.loadBatchMeta(sessionID: sessionID) else {
            return nil
        }

        return ResolvedAnchors(
            micStartDate: meta.micStartDate,
            sysStartDate: meta.sysStartDate,
            micSampleRate: nil,
            sysSampleRate: meta.sysEffectiveSampleRate
        )
    }

}

enum BatchAudioSampleReader {
    static func readAll(
        url: URL,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        file.framePosition = 0
        return try readChunk(
            from: file,
            frameCount: AVAudioFrameCount(file.length),
            targetRate: targetRate,
            overrideSampleRate: overrideSampleRate
        )
    }

    static func readChunk(
        from file: AVAudioFile,
        frameCount: AVAudioFrameCount,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) throws -> [Float] {
        let srcFormat = file.processingFormat
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: readBuf)
        return resample(readBuf, targetRate: targetRate, overrideSampleRate: overrideSampleRate)
    }

    static func resample(
        _ readBuf: AVAudioPCMBuffer,
        targetRate: Double,
        overrideSampleRate: Double? = nil
    ) -> [Float] {
        let srcFormat = readBuf.format
        guard readBuf.frameLength > 0 else { return [] }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!

        if overrideSampleRate == nil,
           srcFormat.sampleRate == targetRate,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32
        {
            return extractSamples(from: readBuf)
        }

        let converterInput: AVAudioPCMBuffer
        let converterSrcFormat: AVAudioFormat
        if let overrideSampleRate, overrideSampleRate != srcFormat.sampleRate {
            guard let retaggedFormat = AVAudioFormat(
                commonFormat: srcFormat.commonFormat,
                sampleRate: overrideSampleRate,
                channels: srcFormat.channelCount,
                interleaved: srcFormat.isInterleaved
            ),
            let retaggedBuffer = AVAudioPCMBuffer(
                pcmFormat: retaggedFormat,
                frameCapacity: readBuf.frameCapacity
            )
            else {
                return extractMonoSamples(from: readBuf)
            }
            retaggedBuffer.frameLength = readBuf.frameLength
            if let src = readBuf.floatChannelData, let dst = retaggedBuffer.floatChannelData {
                for ch in 0..<Int(srcFormat.channelCount) {
                    memcpy(dst[ch], src[ch], Int(readBuf.frameLength) * MemoryLayout<Float>.size)
                }
            }
            converterInput = retaggedBuffer
            converterSrcFormat = retaggedFormat
        } else {
            converterInput = readBuf
            converterSrcFormat = srcFormat
        }

        guard let converter = AVAudioConverter(from: converterSrcFormat, to: targetFormat) else {
            return extractMonoSamples(from: converterInput)
        }

        let ratio = targetRate / converterSrcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(converterInput.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return []
        }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputRef = converterInput
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputRef
        }

        return extractSamples(from: outBuf)
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

// MARK: - JSONDecoder Extension

extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
