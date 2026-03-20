import XCTest
@testable import OpenOats

// MARK: - Mock Audio Signal Source

/// Controllable signal source for testing MeetingDetector without CoreAudio.
final class MockAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    let signals: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

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

// MARK: - Thread-Safe Event Collector

/// Collects MeetingDetectionEvents from an async stream using NSLock for
/// thread safety under Swift 6 strict concurrency.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [MeetingDetector.MeetingDetectionEvent] = []

    var events: [MeetingDetector.MeetingDetectionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: MeetingDetector.MeetingDetectionEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

// MARK: - Tests

final class MeetingDetectorTests: XCTestCase {

    // MARK: - Lifecycle Tests

    func testStartIsIdempotent() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        await detector.start()
        await detector.start() // second call should be a no-op

        let active = await detector.isActive
        XCTAssertFalse(active, "Detector should not be active immediately after start")

        await detector.stop()
        source.finish()
    }

    func testStopClearsState() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)

        await detector.start()
        await detector.stop()

        let active = await detector.isActive
        let app = await detector.detectedApp
        XCTAssertFalse(active, "isActive should be false after stop")
        XCTAssertNil(app, "detectedApp should be nil after stop")

        source.finish()
    }

    // MARK: - Signal Handling Tests

    func testMicDeactivationWhileInactiveIsNoOp() async throws {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)
        let collector = EventCollector()

        let stream = await detector.events
        let listenTask = Task {
            for await event in stream {
                collector.append(event)
            }
        }

        await detector.start()

        // Emit false without a prior true -- should produce no events.
        source.emit(false)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(collector.events.isEmpty, "No events expected for mic-off without prior mic-on")

        await detector.stop()
        source.finish()
        listenTask.cancel()
    }

    func testBriefMicActivationProducesDetectedThenEnded() async throws {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)
        let collector = EventCollector()

        let stream = await detector.events
        let listenTask = Task {
            for await event in stream {
                collector.append(event)
            }
        }

        await detector.start()

        // Brief mic activation: true then false after 500ms.
        // The for-await loop in MeetingDetector processes signals sequentially,
        // so the false signal is queued behind the 5s debounce sleep.
        source.emit(true)
        try await Task.sleep(for: .milliseconds(500))
        source.emit(false)

        // Wait for the debounce (5s) plus processing time.
        try await Task.sleep(for: .seconds(6))

        let collected = collector.events
        XCTAssertEqual(collected.count, 2, "Expected .detected then .ended, got \(collected)")

        if collected.count >= 1 {
            if case .detected = collected[0] {
                // pass
            } else {
                XCTFail("First event should be .detected, got \(collected[0])")
            }
        }
        if collected.count >= 2 {
            if case .ended = collected[1] {
                // pass
            } else {
                XCTFail("Second event should be .ended, got \(collected[1])")
            }
        }

        await detector.stop()
        source.finish()
        listenTask.cancel()
    }

    func testDetectedEventEmittedAfterDebounce() async throws {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)
        let collector = EventCollector()

        let stream = await detector.events
        let listenTask = Task {
            for await event in stream {
                collector.append(event)
            }
        }

        await detector.start()

        source.emit(true)

        // Wait for debounce (5s) plus margin.
        try await Task.sleep(for: .seconds(5.5))

        let collected = collector.events
        XCTAssertEqual(collected.count, 1, "Expected exactly one .detected event after debounce")

        if let first = collected.first {
            if case .detected = first {
                // pass
            } else {
                XCTFail("Expected .detected, got \(first)")
            }
        }

        let active = await detector.isActive
        XCTAssertTrue(active, "isActive should be true after debounce confirms detection")

        await detector.stop()
        source.finish()
        listenTask.cancel()
    }

    func testEndedEventEmittedOnMicDeactivation() async throws {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(audioSource: source)
        let collector = EventCollector()

        let stream = await detector.events
        let listenTask = Task {
            for await event in stream {
                collector.append(event)
            }
        }

        await detector.start()

        // Activate mic, wait for debounce, then deactivate.
        source.emit(true)
        try await Task.sleep(for: .seconds(5.5))
        source.emit(false)
        try await Task.sleep(for: .milliseconds(500))

        let collected = collector.events
        XCTAssertEqual(collected.count, 2, "Expected [.detected, .ended], got \(collected)")

        if collected.count >= 1 {
            if case .detected = collected[0] {} else {
                XCTFail("First event should be .detected")
            }
        }
        if collected.count >= 2 {
            if case .ended = collected[1] {} else {
                XCTFail("Second event should be .ended")
            }
        }

        await detector.stop()
        source.finish()
        listenTask.cancel()
    }

    // MARK: - Resource Loading Tests

    func testMeetingAppsJsonLoadsFromBundle() throws {
        guard let url = Bundle.module.url(forResource: "meeting-apps", withExtension: "json") else {
            XCTFail("meeting-apps.json not found in bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([MeetingAppEntry].self, from: data)
        XCTAssertFalse(entries.isEmpty, "meeting-apps.json should not be empty")

        let bundleIDs = entries.map(\.bundleID)
        XCTAssertTrue(bundleIDs.contains("us.zoom.xos"), "meeting-apps.json should contain Zoom")
    }

    // MARK: - Custom Bundle ID Tests

    func testCustomBundleIDsAccepted() async {
        let source = MockAudioSignalSource()
        let detector = MeetingDetector(
            audioSource: source,
            customBundleIDs: ["com.example.custom-meeting-app"]
        )

        // Just verify construction succeeds and basic operations work.
        await detector.start()

        let active = await detector.isActive
        XCTAssertFalse(active, "Should not be active before any signals")

        await detector.stop()
        source.finish()
    }
}
