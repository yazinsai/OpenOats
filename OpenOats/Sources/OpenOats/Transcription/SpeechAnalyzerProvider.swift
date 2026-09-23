@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

// MARK: - Asset-checking seam

@available(macOS 26, *)
protocol SpeechAssetChecking: Sendable {
    func supportedLocales() async -> [Locale]
    func installedLocales() async -> [Locale]
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func status(for modules: [any SpeechModule]) async -> AssetInventory.Status
    func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest?
    func reservedLocales() async -> [Locale]
    func release(reservedLocale: Locale) async -> Bool
}

@available(macOS 26, *)
struct DefaultSpeechAssetChecker: SpeechAssetChecking {
    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func status(for modules: [any SpeechModule]) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: modules)
    }

    func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: modules)
    }

    func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    func release(reservedLocale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: reservedLocale)
    }
}

// MARK: - Provider

@available(macOS 26, *)
final class SpeechAnalyzerProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    let displayName = "Apple SpeechAnalyzer"

    private let assets: any SpeechAssetChecking
    private let preparedLocaleIdentifiers = OSAllocatedUnfairLock(initialState: Set<String>())

    init(assets: any SpeechAssetChecking = DefaultSpeechAssetChecker()) {
        self.assets = assets
    }

    func checkStatus(locale: Locale) async -> BackendStatus {
        guard let resolved = await assets.supportedLocale(equivalentTo: locale) else {
            return .error(
                reason: "SpeechAnalyzer does not support locale \"\(locale.identifier)\". Choose a supported locale in Settings or switch to Parakeet."
            )
        }

        if await isInstalled(resolved) {
            return .ready
        }

        return .needsDownload(prompt: TranscriptionModel.speechAnalyzer.downloadPrompt)
    }

    func prepare(
        locale: Locale,
        onStatus: @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let resolved = await assets.supportedLocale(equivalentTo: locale) else {
            throw StreamingTranscriptionError.unsupportedLocale(locale.identifier)
        }

        let probe = makeTranscriber(locale: resolved)
        let modules: [any SpeechModule] = [probe]

        let status = await assets.status(for: modules)
        if status != .installed {
            onStatus("Downloading Apple speech assets…")
            try await downloadAssets(modules: modules, keeping: resolved, onProgress: onProgress)
        }

        onStatus("Apple SpeechAnalyzer ready")
        onProgress(1.0)
        markPrepared(resolved)
    }

    func makeSession(locale: Locale) async throws -> any StreamingTranscriptionSession {
        guard let resolved = await assets.supportedLocale(equivalentTo: locale) else {
            throw StreamingTranscriptionError.unsupportedLocale(locale.identifier)
        }

        let alreadyPrepared = preparedLocaleIdentifiers.withLock {
            $0.contains(Self.localeKey(resolved))
        }
        if !alreadyPrepared {
            guard await isInstalled(resolved) else {
                throw StreamingTranscriptionError.notPrepared
            }
            markPrepared(resolved)
        }

        return SpeechAnalyzerSession(locale: resolved)
    }

    // MARK: - Private

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    private func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await assets.installedLocales()
        for candidate in installed {
            if candidate == locale {
                return true
            }
            if let equiv = await assets.supportedLocale(equivalentTo: candidate), equiv == locale {
                return true
            }
        }
        return false
    }

    private func markPrepared(_ locale: Locale) {
        _ = preparedLocaleIdentifiers.withLock { state in
            state.insert(Self.localeKey(locale))
        }
    }

    private static func localeKey(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    private func downloadAssets(
        modules: [any SpeechModule],
        keeping locale: Locale,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        do {
            try await performDownload(modules: modules, onProgress: onProgress)
        } catch {
            await releaseOtherReservedLocales(keeping: locale)
            do {
                try await performDownload(modules: modules, onProgress: onProgress)
            } catch {
                throw StreamingTranscriptionError.assetInstallFailed(error.localizedDescription)
            }
        }
    }

    private func performDownload(
        modules: [any SpeechModule],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let request = try await assets.assetInstallationRequest(supporting: modules) else {
            // No install request usually means assets are already present / not needed.
            onProgress(1.0)
            return
        }

        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { observation.invalidate() }

        try await request.downloadAndInstall()
        onProgress(1.0)
    }

    private func releaseOtherReservedLocales(keeping locale: Locale) async {
        let reserved = await assets.reservedLocales()
        for reservedLocale in reserved where reservedLocale != locale {
            _ = await assets.release(reservedLocale: reservedLocale)
        }
    }
}

// MARK: - Session

@available(macOS 26, *)
actor SpeechAnalyzerSession: StreamingTranscriptionSession {
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var didFinish = false

    init(locale: Locale) {
        self.locale = locale
    }

    /// AVAudioPCMBuffer is not Sendable; box the stream so the protocol entry point can hop into the actor.
    private struct PCMStreamBox: @unchecked Sendable {
        let stream: AsyncStream<AVAudioPCMBuffer>
    }

    nonisolated func run(
        stream: AsyncStream<AVAudioPCMBuffer>,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void
    ) async {
        await runIsolated(
            stream: PCMStreamBox(stream: stream),
            onPartial: onPartial,
            onFinal: onFinal
        )
    }

    private func runIsolated(
        stream: PCMStreamBox,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void
    ) async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            onPartial("")
            return
        }
        targetFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let timing = Self.timing(from: result)
                        onPartial("")
                        onFinal(
                            StreamingTranscriber.FinalSegment(
                                text: text,
                                startTime: timing.start,
                                endTime: timing.end
                            )
                        )
                    } else {
                        onPartial(text)
                    }
                }
            } catch is CancellationError {
                // Expected during teardown.
            } catch {
                // Analyzer/results failures surface via empty partials; finish() still tears down.
            }
        }

        startTask = Task {
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                // Expected during teardown.
            } catch {
                // Surface via finish path; keep run() from throwing across actor boundary.
            }
        }

        for await buffer in stream.stream {
            if Task.isCancelled || didFinish { break }
            guard let converted = convert(buffer) else { continue }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        continuation.finish()
    }

    func finish() async {
        guard !didFinish else { return }
        didFinish = true

        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }

        await resultsTask?.value
        await startTask?.value

        resultsTask = nil
        startTask = nil
        analyzer = nil
        converter = nil
        converterInputFormat = nil
        targetFormat = nil
    }

    // MARK: - Audio conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let targetFormat else { return nil }

        let inputFormat = buffer.format
        if formatsMatch(inputFormat, targetFormat) {
            return buffer
        }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    private func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    // MARK: - Timing

    private static func timing(from result: SpeechTranscriber.Result) -> (start: TimeInterval, end: TimeInterval) {
        var minStart: TimeInterval?
        var maxEnd: TimeInterval?

        for run in result.text.runs {
            guard let timeRange = run.attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                continue
            }
            guard timeRange.start.isNumeric, timeRange.duration.isNumeric else { continue }
            let start = CMTimeGetSeconds(timeRange.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))
            guard start.isFinite, end.isFinite else { continue }
            minStart = min(minStart ?? start, start)
            maxEnd = max(maxEnd ?? end, end)
        }

        if let minStart, let maxEnd {
            return (minStart, maxEnd)
        }

        let range = result.range
        if range.start.isNumeric, range.duration.isNumeric, CMTimeGetSeconds(range.duration) > 0 {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            if start.isFinite, end.isFinite {
                return (start, end)
            }
        }

        return (0, 0)
    }
}
