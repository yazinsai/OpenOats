import XCTest
@testable import OpenOats

// MARK: - Mock Audio Signal Source

/// Controllable signal source for testing MeetingDetector without CoreAudio.
final class MockAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    private let continuation: AsyncStream<Bool>.Continuation
    let signals: AsyncStream<Bool>

    init() {
        var captured: AsyncStream<Bool>.Continuation!
        self.signals = AsyncStream<Bool> { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func emit(_ value: Bool) {
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}

/// Thread-safe event collector for test assertions.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [MeetingDetector.MeetingDetectionEvent] = []

    var events: [MeetingDetector.MeetingDetectionEvent] {
        lock.withLock { _events }
    }

    var count: Int {
        lock.withLock { _events.count }
    }

    func append(_ event: MeetingDetector.MeetingDetectionEvent) {
        lock.withLock { _events.append(event) }
    }
}

// MARK: - MeetingDetector Tests

final class MeetingDetectorTests: XCTestCase {

    // MARK: - Lifecycle

    func testStartIsIdempotent() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        await detector.start()
        await detector.start()

        let isActive = await detector.isActive
        XCTAssertFalse(isActive, "Should not be active before any signal")

        source.finish()
        await detector.stop()
    }

    func testStopClearsState() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        await detector.start()
        await detector.stop()

        let isActive = await detector.isActive
        XCTAssertFalse(isActive)
        let app = await detector.detectedApp
        XCTAssertNil(app)
        source.finish()
    }

    // MARK: - Mic Signal: Deactivation

    func testMicDeactivationWhileInactiveIsNoOp() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        await detector.start()
        source.emit(false)

        try? await Task.sleep(for: .milliseconds(50))

        let isActive = await detector.isActive
        XCTAssertFalse(isActive, "Deactivation while inactive should be a no-op")
        source.finish()
        await detector.stop()
    }

    // MARK: - Debounce

    func testBriefMicActivationProducesDetectedThenEnded() async {
        // The for-await loop processes signals sequentially: the deactivation
        // is queued behind the debounce sleep. So a brief mic activation
        // still emits .detected once the sleep completes, immediately followed
        // by .ended when the deactivation signal is processed.
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        let collector = EventCollector()
        let stream = await detector.events
        let collectTask = Task {
            for await event in stream {
                collector.append(event)
                if collector.count >= 2 { break }
            }
        }

        await detector.start()

        source.emit(true)
        try? await Task.sleep(for: .milliseconds(500))
        source.emit(false)

        // Wait for debounce + processing
        try? await Task.sleep(for: .milliseconds(6_000))

        let events = collector.events
        XCTAssertEqual(events.count, 2)
        if case .detected = events.first {} else {
            XCTFail("First event should be .detected")
        }
        if case .ended = events.last {} else {
            XCTFail("Second event should be .ended")
        }

        // Final state should be inactive
        let isActive = await detector.isActive
        XCTAssertFalse(isActive)

        collectTask.cancel()
        source.finish()
        await detector.stop()
    }

    // MARK: - Event Stream

    func testDetectedEventEmittedAfterDebounce() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        let collector = EventCollector()
        let stream = await detector.events
        let collectTask = Task {
            for await event in stream {
                collector.append(event)
                break
            }
        }

        await detector.start()
        source.emit(true)

        // Wait for debounce (5s) + buffer
        try? await Task.sleep(for: .milliseconds(5_500))

        let events = collector.events
        XCTAssertEqual(events.count, 1, "Should have emitted exactly one event after debounce")
        if case .detected = events.first {} else {
            XCTFail("Expected .detected event")
        }

        let isActive = await detector.isActive
        XCTAssertTrue(isActive)

        collectTask.cancel()
        source.finish()
        await detector.stop()
    }

    func testEndedEventEmittedOnMicDeactivation() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        let collector = EventCollector()
        let stream = await detector.events
        let collectTask = Task {
            for await event in stream {
                collector.append(event)
                if collector.count >= 2 { break }
            }
        }

        await detector.start()

        // Activate and wait for debounce
        source.emit(true)
        try? await Task.sleep(for: .milliseconds(5_500))

        // Deactivate
        source.emit(false)
        try? await Task.sleep(for: .milliseconds(100))

        let events = collector.events
        XCTAssertEqual(events.count, 2)
        if case .detected = events.first {} else {
            XCTFail("First event should be .detected")
        }
        if case .ended = events.last {} else {
            XCTFail("Second event should be .ended")
        }

        collectTask.cancel()
        source.finish()
        await detector.stop()
    }

    // MARK: - Known Apps JSON

    func testMeetingAppsJsonLoadsFromBundle() throws {
        guard let url = Bundle.module.url(forResource: "meeting-apps", withExtension: "json") else {
            XCTFail("meeting-apps.json not found in bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let apps = try JSONDecoder().decode([MeetingAppEntry].self, from: data)

        XCTAssertGreaterThan(apps.count, 0, "Should have at least one known meeting app")

        let zoom = apps.first(where: { $0.bundleID == "us.zoom.xos" })
        XCTAssertNotNil(zoom)
        XCTAssertEqual(zoom?.displayName, "Zoom")
    }

    func testCustomBundleIDsAccepted() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(
            audioSource: source,
            customBundleIDs: ["com.example.custom-meeting"]
        )

        await detector.start()
        let isActive = await detector.isActive
        XCTAssertFalse(isActive)

        source.finish()
        await detector.stop()
    }
}
