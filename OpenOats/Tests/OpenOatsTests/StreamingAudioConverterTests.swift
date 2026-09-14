import AVFoundation
import XCTest
@testable import OpenOatsKit

final class StreamingAudioConverterTests: XCTestCase {
    private func tone(rate: Double, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * 440 * Double(frame) / rate))
            }
        }
        return buffer
    }

    func testOneSecondAt48kConvertsToOneSecondAt16k() throws {
        let samples = try XCTUnwrap(StreamingAudioConverter().extractSamples(tone(rate: 48_000)))
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 32)
        let risingCrossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        XCTAssertEqual(Double(risingCrossings), 440, accuracy: 2)
    }

    func testConsumerDelayDoesNotChangePitchOrDuration() async throws {
        let converter = StreamingAudioConverter()
        let first = try XCTUnwrap(converter.extractSamples(tone(rate: 48_000)))
        // Exceed the former 3 s wall-clock rate-estimation window, simulating
        // a slow ASR call before the next queued buffer is consumed.
        try await Task.sleep(for: .milliseconds(3100))
        let delayed = try XCTUnwrap(converter.extractSamples(tone(rate: 48_000)))
        // AVAudioConverter can withhold a few priming frames on its first call.
        XCTAssertEqual(Double(first.count), Double(delayed.count), accuracy: 32)
        let risingCrossings = zip(delayed, delayed.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        XCTAssertEqual(Double(risingCrossings), 440, accuracy: 2)
    }

    func testFormatChangeRebuildsTheConverter() throws {
        let converter = StreamingAudioConverter()
        _ = try XCTUnwrap(converter.extractSamples(tone(rate: 48_000)))
        let changed = try XCTUnwrap(converter.extractSamples(tone(rate: 44_100, channels: 2)))
        XCTAssertEqual(Double(changed.count), 16_000, accuracy: 32)
    }
}
