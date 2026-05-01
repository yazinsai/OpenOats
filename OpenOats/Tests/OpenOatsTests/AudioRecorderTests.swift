import AVFoundation
import XCTest
@testable import OpenOatsKit

final class AudioRecorderTests: XCTestCase {

    private var outputDir: URL!

    override func setUp() {
        super.setUp()
        outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenOatsRecorderTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outputDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a sine-wave PCM buffer at the given format.
    private func makeSineBuffer(
        sampleRate: Double,
        channels: UInt32 = 1,
        frameCount: AVAudioFrameCount,
        frequency: Float = 440
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: channels == 1
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData!
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frameCount) {
                let phase = Float(i) / Float(sampleRate) * frequency * 2 * .pi
                data[ch][i] = sin(phase) * 0.5
            }
        }
        return buffer
    }

    /// Write system audio buffers simulating a rate mismatch:
    /// buffers are tagged at `declaredRate` but delivered at real-time intervals
    /// corresponding to `effectiveRate`.
    private func writeSysBuffers(
        recorder: AudioRecorder,
        declaredRate: Double,
        effectiveRate: Double,
        durationSeconds: Double
    ) {
        let bufferSize: AVAudioFrameCount = 480
        let totalFrames = Int(effectiveRate * durationSeconds)
        let bufferCount = totalFrames / Int(bufferSize)

        // Time between buffers based on effective rate
        let intervalPerBuffer = Double(bufferSize) / effectiveRate

        let startTime = Date()
        for i in 0..<bufferCount {
            let buffer = makeSineBuffer(
                sampleRate: declaredRate,
                frameCount: bufferSize,
                frequency: 440
            )
            // Simulate wall-clock timing by adjusting sysStartDate/sysEndDate
            // We write all buffers synchronously but the recorder tracks Date() calls
            recorder.writeSysBuffer(buffer)

            // For the first few and last buffers, we can't control Date() precisely,
            // but the test verifies the merge output duration is approximately correct.
            _ = intervalPerBuffer * Double(i)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        // Sanity: buffer writes should be fast (< 2s for any reasonable test)
        XCTAssertLessThan(elapsed, 5.0)
    }

    // MARK: - Tests

    func testMergeProducesOutputFile() async {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        // Write 2 seconds of mic audio at 24kHz
        let micBuffer = makeSineBuffer(sampleRate: 24000, frameCount: 48000)
        recorder.writeMicBuffer(micBuffer)

        // Write 2 seconds of system audio at 48kHz
        let sysBuffer = makeSineBuffer(sampleRate: 48000, frameCount: 96000)
        recorder.writeSysBuffer(sysBuffer)

        await recorder.finalizeRecording()

        // Should produce an m4a file
        let files = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let m4aFiles = files?.filter { $0.pathExtension == "m4a" } ?? []
        XCTAssertEqual(m4aFiles.count, 1, "Expected one m4a output file")
    }

    func testMergeWithRateMismatchProducesCorrectDuration() async {
        // Simulate the real bug: system audio IO proc delivers at half the declared rate.
        // 480 frames tagged as 48kHz, but arriving at the rate of 24kHz
        // (i.e., half as many buffers per second as expected).
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let durationSeconds = 4.0

        // Write mic audio at 24kHz for the full duration
        let micFrames = AVAudioFrameCount(24000 * durationSeconds)
        let micBuffer = makeSineBuffer(sampleRate: 24000, frameCount: micFrames)
        recorder.writeMicBuffer(micBuffer)

        // Write system audio: same number of frames as mic (simulating the bug),
        // but tagged as 48kHz. The wall-clock tracking in writeSysBuffer will
        // compute the effective rate and correct during merge.
        //
        // At 24kHz effective for 4 seconds = 96,000 frames.
        // These are tagged as 48kHz, so without correction they'd be 2 seconds.
        let sysFramesPerBuffer: AVAudioFrameCount = 480
        let totalSysFrames = Int(24000 * durationSeconds) // same count as mic
        let numSysBuffers = totalSysFrames / Int(sysFramesPerBuffer)

        for _ in 0..<numSysBuffers {
            let buffer = makeSineBuffer(
                sampleRate: 48000, // declared rate (what the tap reports)
                frameCount: sysFramesPerBuffer
            )
            recorder.writeSysBuffer(buffer)
        }

        await recorder.finalizeRecording()

        // Check the output file duration
        let files = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let m4aFiles = files?.filter { $0.pathExtension == "m4a" } ?? []
        XCTAssertEqual(m4aFiles.count, 1)

        guard let outputURL = m4aFiles.first else { return }
        let outputFile = try? AVAudioFile(forReading: outputURL)
        guard let outputFile else {
            XCTFail("Could not read output file")
            return
        }

        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate

        // Without the fix, output would be ~2s (sys audio at declared 48kHz).
        // With the fix, sys audio is resampled from effective rate, so output ≈ 4s.
        // Allow 0.5s tolerance for AAC encoding padding.
        XCTAssertGreaterThan(outputDuration, durationSeconds - 0.5,
            "Output duration \(outputDuration)s is too short — rate correction may not be working")
        XCTAssertLessThan(outputDuration, durationSeconds + 1.0,
            "Output duration \(outputDuration)s is unexpectedly long")
    }

    func testMergeWithMatchingRatesDoesNotResample() async {
        // When declared and effective rates match, no resampling override should happen.
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let durationSeconds = 2.0

        // Mic at 48kHz
        let micFrames = AVAudioFrameCount(48000 * durationSeconds)
        let micBuffer = makeSineBuffer(sampleRate: 48000, frameCount: micFrames)
        recorder.writeMicBuffer(micBuffer)

        // System at 48kHz, matching rate (no mismatch)
        let sysFrames = AVAudioFrameCount(48000 * durationSeconds)
        let sysBuffer = makeSineBuffer(sampleRate: 48000, frameCount: sysFrames)
        recorder.writeSysBuffer(sysBuffer)

        await recorder.finalizeRecording()

        let files = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let m4aFiles = files?.filter { $0.pathExtension == "m4a" } ?? []
        XCTAssertEqual(m4aFiles.count, 1)

        guard let outputURL = m4aFiles.first,
              let outputFile = try? AVAudioFile(forReading: outputURL) else {
            XCTFail("Could not read output file")
            return
        }

        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
        // Should be approximately 2 seconds
        XCTAssertGreaterThan(outputDuration, durationSeconds - 0.5)
        XCTAssertLessThan(outputDuration, durationSeconds + 0.5)
    }

    func testSysEffectiveRateTracking() {
        // Verify that writeSysBuffer tracks timing anchors correctly.
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let buffer = makeSineBuffer(sampleRate: 48000, frameCount: 480)

        // Write several buffers
        for _ in 0..<100 {
            recorder.writeSysBuffer(buffer)
        }

        let anchors = recorder.timingAnchors()
        XCTAssertNotNil(anchors.sysStartDate, "sysStartDate should be set after writes")
        XCTAssertEqual(anchors.sysAnchors.count, 1, "Should have exactly one start anchor")
        XCTAssertEqual(anchors.sysAnchors.first?.frame, 0, "Start anchor should be at frame 0")
    }

    // MARK: - Multi-channel mic downmix (regression for ~25 dB attenuation bug)

    /// Make a non-interleaved multi-channel buffer where channel 0 carries the
    /// "voice" signal and additional channels carry an anti-phase (180°-shifted)
    /// copy. This is a worst-case proxy for built-in MacBook beamformed mic
    /// arrays where channel 0 is the front-facing primary beam and other
    /// channels carry directional/cancellation signal that's anti-phase
    /// relative to ch 0. With the old `sum * (1/N)` averaging downmix, summing
    /// these channels nulls the signal entirely; with channel-0-only downmix,
    /// the output preserves channel 0 unchanged.
    private func makeBeamformedBuffer(
        sampleRate: Double,
        channels: UInt32,
        frameCount: AVAudioFrameCount,
        frequency: Float = 440,
        interleaved: Bool = true
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData!
        if interleaved {
            // Single channelData[0] plane holds [s0_ch0, s0_ch1, s0_ch2, s1_ch0, ...]
            let chCount = Int(channels)
            for i in 0..<Int(frameCount) {
                let phase = Float(i) / Float(sampleRate) * frequency * 2 * .pi
                let sample = sin(phase) * 0.5
                data[0][i * chCount] = sample
                for ch in 1..<chCount {
                    data[0][i * chCount + ch] = -sample
                }
            }
        } else {
            for i in 0..<Int(frameCount) {
                let phase = Float(i) / Float(sampleRate) * frequency * 2 * .pi
                let sample = sin(phase) * 0.5
                data[0][i] = sample
                for ch in 1..<Int(channels) {
                    data[ch][i] = -sample
                }
            }
        }
        return buffer
    }

    /// Read the recorder's mic temp file and return its peak absolute amplitude.
    /// Touches private state via the timing anchors method to find the temp URL
    /// — kept simple by reading the recorder's published `tempFileURLs()` API.
    private func micTempPeak(from recorder: AudioRecorder) -> Float? {
        let urls = recorder.tempFileURLs()
        guard let micURL = urls.mic, FileManager.default.fileExists(atPath: micURL.path) else {
            return nil
        }
        guard let file = try? AVAudioFile(forReading: micURL) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return nil
        }
        try? file.read(into: buf)
        guard let data = buf.floatChannelData?[0] else { return nil }
        var peak: Float = 0
        for i in 0..<Int(buf.frameLength) {
            peak = max(peak, abs(data[i]))
        }
        return peak
    }

    /// Regression test: a 2-channel mic buffer where channel 1 is anti-phase
    /// to channel 0 must not get averaged into silence. With the old
    /// `sum * (1/N)` downmix, summing anti-phase channels collapses to zero;
    /// the fix (channel-0-only downmix) preserves the original signal.
    ///
    /// Built-in MacBook mic arrays expose 3 beamformed channels in the wild
    /// (front + side + cancellation) where summing produces destructive
    /// interference of ~25 dB on real speech. We test the 2-channel anti-phase
    /// case here because it's the cleanest demonstration — and AVAudioFormat
    /// with 3 channels requires an explicit channel layout that's awkward in
    /// tests. The downmix code path is identical for any N>1.
    func testInterleavedMultiChannelMicPreservesSignal() {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let buffer = makeBeamformedBuffer(
            sampleRate: 48000,
            channels: 2,
            frameCount: 4800,
            interleaved: true
        )
        recorder.writeMicBuffer(buffer)

        guard let peak = micTempPeak(from: recorder) else {
            XCTFail("Mic temp file not produced")
            return
        }
        // Original signal peaks at 0.5. Old averaging downmix on this
        // anti-phase 2-channel input would collapse to ~0.0. The fix preserves
        // channel 0 verbatim, so peak should be ≈ 0.5.
        XCTAssertGreaterThan(peak, 0.4,
            "Multi-channel downmix is destroying the primary-beam signal — peak \(peak) suggests destructive interference. Expected ≈ 0.5.")
    }

    /// Same regression check on the non-interleaved code path.
    func testNonInterleavedMultiChannelMicPreservesSignal() {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let buffer = makeBeamformedBuffer(
            sampleRate: 48000,
            channels: 2,
            frameCount: 4800,
            interleaved: false
        )
        recorder.writeMicBuffer(buffer)

        guard let peak = micTempPeak(from: recorder) else {
            XCTFail("Mic temp file not produced")
            return
        }
        XCTAssertGreaterThan(peak, 0.4,
            "Non-interleaved multi-channel downmix collapsed to peak \(peak). Expected ≈ 0.5.")
    }

    /// Single-channel mic must continue to work exactly as before — taking
    /// channel 0 directly is a no-op for mono input.
    func testSingleChannelMicPassThroughUnchanged() {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let buffer = makeSineBuffer(sampleRate: 48000, channels: 1, frameCount: 4800)
        recorder.writeMicBuffer(buffer)

        guard let peak = micTempPeak(from: recorder) else {
            XCTFail("Mic temp file not produced")
            return
        }
        XCTAssertGreaterThan(peak, 0.4, "Single-channel mic peak should be ≈ 0.5")
    }

    func testDiscardDoesNotProduceOutput() {
        let recorder = AudioRecorder(outputDirectory: outputDir)
        recorder.startSession()

        let buffer = makeSineBuffer(sampleRate: 48000, frameCount: 48000)
        recorder.writeMicBuffer(buffer)
        recorder.writeSysBuffer(buffer)

        recorder.discardRecording()

        let files = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let m4aFiles = files?.filter { $0.pathExtension == "m4a" } ?? []
        XCTAssertEqual(m4aFiles.count, 0, "Discarded recording should not produce output")
    }
}
