import AVFoundation
import XCTest
@testable import OpenOatsKit

final class BatchAudioTranscriberTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsBatchAudioTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testReadAllHonorsOverrideSampleRateForMismatchedBatchAudio() throws {
        let audioURL = tempDir.appendingPathComponent("sys.caf")
        let declaredRate = 48_000.0
        let effectiveRate = 24_000.0
        let durationSeconds = 4.0
        let frameCount = AVAudioFrameCount(effectiveRate * durationSeconds)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: declaredRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let phase = Float(i) / Float(effectiveRate) * 440 * 2 * .pi
                data[i] = sin(phase) * 0.5
            }
        }

        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)

        let withoutOverride = try BatchAudioSampleReader.readAll(
            url: audioURL,
            targetRate: 16_000
        )
        let withOverride = try BatchAudioSampleReader.readAll(
            url: audioURL,
            targetRate: 16_000,
            overrideSampleRate: effectiveRate
        )

        XCTAssertFalse(withOverride.isEmpty)
        XCTAssertGreaterThan(withOverride.count, withoutOverride.count * 3 / 2)
        XCTAssertEqual(withOverride.count, Int(durationSeconds * 16_000), accuracy: 3_000)
        XCTAssertEqual(withoutOverride.count, Int(durationSeconds * 8_000), accuracy: 3_000)
    }

    func testOverwriteGuardRejectsClearlyCollapsedReplacementTranscript() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = makeRecords(
            count: 8,
            startedAt: startedAt,
            spacing: 45,
            text: "Discussed rollout blockers, merchant onboarding, dashboard regressions, and production follow-up."
        )
        let replacement = makeRecords(
            count: 2,
            startedAt: startedAt,
            spacing: 20,
            text: "Quick update."
        )

        let reason = BatchTranscriptOverwriteGuard.rejectionReason(
            existingRecords: existing,
            replacementRecords: replacement
        )

        XCTAssertEqual(reason, "Batch re-transcription looks unreliable; kept existing transcript")
    }

    func testOverwriteGuardAllowsComparableReplacementWithFewerSegments() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = makeRecords(
            count: 8,
            startedAt: startedAt,
            spacing: 40,
            text: "Reviewed customer issues, rollout readiness, pricing follow-ups, and ownership for the next sprint."
        )
        let replacement = makeRecords(
            count: 3,
            startedAt: startedAt,
            spacing: 90,
            text: "Reviewed customer issues, rollout readiness, pricing follow-ups, ownership, and next sprint planning in detail."
        )

        let reason = BatchTranscriptOverwriteGuard.rejectionReason(
            existingRecords: existing,
            replacementRecords: replacement
        )

        XCTAssertNil(reason)
    }

    func testOverwriteGuardIgnoresSmallExistingTranscript() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = makeRecords(
            count: 2,
            startedAt: startedAt,
            spacing: 15,
            text: "Tiny meeting."
        )
        let replacement = makeRecords(
            count: 1,
            startedAt: startedAt,
            spacing: 10,
            text: "Short."
        )

        let reason = BatchTranscriptOverwriteGuard.rejectionReason(
            existingRecords: existing,
            replacementRecords: replacement
        )

        XCTAssertNil(reason)
    }

    func testSpeakerRunsSplitSegmentAcrossSpeakerBoundaries() {
        let segment = BatchTranscriptionSegmentLayout.SegmentWindow(
            startTime: 100,
            endTime: 112,
            sampleRate: 16_000
        )
        let runs = [
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 100, endTime: 104, speaker: .remote(1)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 104, endTime: 108, speaker: .remote(2)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 108, endTime: 112, speaker: .remote(1))
        ]

        let slices = BatchTranscriptionSegmentLayout.slices(
            for: segment,
            diarizedRuns: runs,
            fallbackSpeaker: .them
        )

        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices.map(\.speaker), [.remote(1), .remote(2), .remote(1)])
        XCTAssertEqual(slices.map(\.startSample), [0, 64_000, 128_000])
        XCTAssertEqual(slices.map(\.sampleCount), [64_000, 64_000, 64_000])
    }

    func testShortSpeakerRunsCollapseBackToFallbackSegment() {
        let segment = BatchTranscriptionSegmentLayout.SegmentWindow(
            startTime: 10,
            endTime: 11.2,
            sampleRate: 16_000
        )
        let runs = [
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 10, endTime: 10.4, speaker: .remote(1)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 10.4, endTime: 10.8, speaker: .remote(2)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 10.8, endTime: 11.2, speaker: .remote(1))
        ]

        let slices = BatchTranscriptionSegmentLayout.slices(
            for: segment,
            diarizedRuns: runs,
            fallbackSpeaker: .them
        )

        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].speaker, .them)
        XCTAssertEqual(slices[0].startSample, 0)
        XCTAssertEqual(slices[0].sampleCount, segment.sampleCount)
    }

    func testTinyLeadingRunIsMergedIntoNeighbor() {
        let segment = BatchTranscriptionSegmentLayout.SegmentWindow(
            startTime: 50,
            endTime: 54,
            sampleRate: 16_000
        )
        let runs = [
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 50, endTime: 50.3, speaker: .remote(1)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 50.3, endTime: 52.3, speaker: .remote(2)),
            BatchTranscriptionSegmentLayout.SpeakerRun(startTime: 52.3, endTime: 54, speaker: .remote(1))
        ]

        let slices = BatchTranscriptionSegmentLayout.slices(
            for: segment,
            diarizedRuns: runs,
            fallbackSpeaker: .them
        )

        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices.map(\.speaker), [.remote(2), .remote(1)])
        XCTAssertEqual(slices.map(\.startSample), [0, 36_800])
        XCTAssertEqual(slices.map(\.sampleCount), [36_800, 27_200])
    }

    private func makeRecords(
        count: Int,
        startedAt: Date,
        spacing: TimeInterval,
        text: String
    ) -> [SessionRecord] {
        (0..<count).map { index in
            SessionRecord(
                speaker: index.isMultiple(of: 2) ? .you : .them,
                text: text,
                timestamp: startedAt.addingTimeInterval(Double(index) * spacing)
            )
        }
    }
}
