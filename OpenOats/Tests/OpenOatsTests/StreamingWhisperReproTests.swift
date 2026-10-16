@preconcurrency import AVFoundation
import FluidAudio
import XCTest
@testable import OpenOatsKit

/// Opt-in end-to-end check: feeds a real recording through the live streaming
/// pipeline (Silero VAD + local Whisper) and reports how much text comes out.
/// Run with OPENOATS_REPRO_WAV=/path/to/16k-mono.wav (optional
/// OPENOATS_REPRO_SECONDS, OPENOATS_REPRO_SPEED, OPENOATS_REPRO_LOCALE).
final class StreamingWhisperReproTests: XCTestCase {
    func testStreamingWhisperTranscribesWholeRecording() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OPENOATS_REPRO_WAV"] else {
            throw XCTSkip("OPENOATS_REPRO_WAV not set")
        }
        let seconds = Double(env["OPENOATS_REPRO_SECONDS"] ?? "180") ?? 180
        let speed = Double(env["OPENOATS_REPRO_SPEED"] ?? "1") ?? 1
        let locale = Locale(identifier: env["OPENOATS_REPRO_LOCALE"] ?? "en-US")

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))

        let whisper = WhisperKitBackend(variant: .largeV3Turbo)
        try await whisper.prepare(onStatus: { _ in }, onProgress: { _ in })
        let backend = LoggingBackend(inner: whisper)
        let vad = try await VadManager()

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var finals: [StreamingTranscriber.FinalSegment] = []
        }
        let collector = Collector()
        let started = Date()

        let transcriber = StreamingTranscriber(
            backend: backend,
            locale: locale,
            vadManager: vad,
            speaker: .you,
            sessionID: nil,
            transcriptionModel: TranscriptionModel.whisperLargeV3Turbo.rawValue,
            flushInterval: TranscriptionModel.whisperLargeV3Turbo.flushIntervalSamples,
            skipPartials: TranscriptionModel.whisperLargeV3Turbo.isCloud,
            onPartial: { _ in },
            onFinal: { segment in
                collector.lock.lock()
                collector.finals.append(segment)
                collector.lock.unlock()
                let wall = Date().timeIntervalSince(started)
                print(String(format: "[final wall=%.1fs audio=%.1f-%.1fs] %@", wall, segment.startTime, segment.endTime, segment.text))
            }
        )

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let runTask = Task.detached { await transcriber.run(stream: stream) }

        // Feed 100 ms buffers, paced like a live capture (scaled by speed).
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var fed: AVAudioFrameCount = 0
        while fed < totalFrames {
            let n = min(chunk, totalFrames - fed)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            try file.read(into: buffer, frameCount: n)
            continuation.yield(buffer)
            fed += n
            let target = Double(fed) / format.sampleRate / speed
            let elapsed = Date().timeIntervalSince(started)
            if target > elapsed {
                try await Task.sleep(nanoseconds: UInt64((target - elapsed) * 1_000_000_000))
            }
        }
        let feedDone = Date().timeIntervalSince(started)
        continuation.finish()
        await runTask.value
        let total = Date().timeIntervalSince(started)

        let words = collector.finals.map(\.text).joined(separator: " ").split(separator: " ").count
        let lastEnd = collector.finals.last?.endTime ?? 0
        print(String(format: "SUMMARY audio=%.0fs feedDone=%.0fs drainDone=%.0fs finals=%d words=%d lastAudioEnd=%.0fs",
                     Double(totalFrames) / format.sampleRate, feedDone, total, collector.finals.count, words, lastEnd))
        XCTAssertGreaterThan(words, 0)
    }
}

/// Prints every backend call so a repro run shows where time and text go.
private final class LoggingBackend: TranscriptionBackend, @unchecked Sendable {
    let inner: any TranscriptionBackend
    init(inner: any TranscriptionBackend) { self.inner = inner }
    var displayName: String { inner.displayName }
    func checkStatus() -> BackendStatus { inner.checkStatus() }
    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        let t0 = Date()
        do {
            let text = try await inner.transcribe(samples, locale: locale, previousContext: previousContext)
            print(String(format: "[call %.1fs audio, ctx=%@, %.2fs] '%@'", Double(samples.count) / 16_000,
                         previousContext == nil ? "nil" : "set", Date().timeIntervalSince(t0), String(text.prefix(60))))
            return text
        } catch {
            print("[call error] \(error)")
            throw error
        }
    }
}
