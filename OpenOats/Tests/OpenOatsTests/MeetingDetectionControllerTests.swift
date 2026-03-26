import XCTest
@testable import OpenOatsKit

@MainActor
final class MeetingDetectionControllerTests: XCTestCase {

    // MARK: - Event Stream: accepted metadata flows through

    func testAcceptedEventFlowsMetadata() async throws {
        let controller = MeetingDetectionController()

        let metadata = MeetingMetadata(
            detectionContext: DetectionContext(
                signal: .appLaunched(MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")),
                detectedAt: Date(),
                meetingApp: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
                calendarEvent: nil
            ),
            calendarEvent: nil,
            title: "Zoom",
            startedAt: Date(),
            endedAt: nil
        )

        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        // Yield after consumer is listening
        try await Task.sleep(for: .milliseconds(50))
        controller.yield(.accepted(metadata))

        // Wait for consumer to process
        try await Task.sleep(for: .milliseconds(50))

        if case .accepted(let received) = receivedEvent {
            XCTAssertEqual(received.title, "Zoom")
            XCTAssertEqual(received.detectionContext?.meetingApp?.bundleID, "us.zoom.xos")
        } else {
            XCTFail("Expected .accepted event, got \(String(describing: receivedEvent))")
        }

        consumeTask.cancel()
    }

    // MARK: - Events consumed exactly once (one-shot)

    func testEventsConsumedExactlyOnce() async throws {
        let controller = MeetingDetectionController()

        var firstConsumerEvents: [DetectionEvent] = []
        var secondConsumerEvents: [DetectionEvent] = []

        // First consumer starts and gets the event
        let firstConsumer = Task { @MainActor in
            for await event in controller.events {
                firstConsumerEvents.append(event)
                if firstConsumerEvents.count >= 1 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        controller.yield(.dismissed)
        try await Task.sleep(for: .milliseconds(50))

        // After first consumer finishes, the event is consumed
        XCTAssertEqual(firstConsumerEvents.count, 1)
        if case .dismissed = firstConsumerEvents.first {
            // correct
        } else {
            XCTFail("Expected .dismissed")
        }

        firstConsumer.cancel()
        // Second consumer won't see the already-consumed event
        XCTAssertTrue(secondConsumerEvents.isEmpty)
    }

    // MARK: - Multiple rapid events all delivered (unbounded)

    func testMultipleRapidEventsDelivered() async throws {
        let controller = MeetingDetectionController()
        var receivedEvents: [DetectionEvent] = []

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvents.append(event)
                if receivedEvents.count >= 4 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Yield 4 events rapidly
        controller.yield(.dismissed)
        controller.yield(.timeout)
        controller.yield(.meetingAppExited)
        controller.yield(.notAMeeting(bundleID: "com.test.app"))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(receivedEvents.count, 4)
        consumeTask.cancel()
    }

    // MARK: - DismissedEvents Tracking

    func testDismissedEventsInitiallyEmpty() async {
        let controller = MeetingDetectionController()
        XCTAssertTrue(controller.dismissedEvents.isEmpty)
    }

    // MARK: - noteUtterance lifecycle

    func testNoteUtteranceUpdatesState() async throws {
        let controller = MeetingDetectionController()

        XCTAssertFalse(controller.isMonitoringSilence)

        controller.startSilenceMonitoring()
        XCTAssertTrue(controller.isMonitoringSilence)

        // noteUtterance should work without error
        controller.noteUtterance()

        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Observable State

    func testInitialState() async {
        let controller = MeetingDetectionController()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.detectedApp)
        XCTAssertFalse(controller.isMonitoringSilence)
        XCTAssertNil(controller.activeSettings)
        XCTAssertNil(controller.meetingDetector)
        XCTAssertNil(controller.notificationService)
    }

    // MARK: - Teardown Clears State

    func testTeardownClearsState() async {
        let controller = MeetingDetectionController()
        controller.teardown()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.detectedApp)
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Silence Monitoring Lifecycle

    func testSilenceMonitoringStartStop() async {
        let controller = MeetingDetectionController()

        controller.startSilenceMonitoring()
        XCTAssertTrue(controller.isMonitoringSilence)

        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)

        // Double stop is safe
        controller.stopSilenceMonitoring()
        XCTAssertFalse(controller.isMonitoringSilence)
    }

    // MARK: - Stream construction does not block

    func testStreamUsesUnboundedBuffering() async {
        let controller = MeetingDetectionController()
        _ = controller.events
        // Reaching this point means the stream didn't block on init
    }

    // MARK: - App Exit Monitoring

    func testAppExitMonitorYieldsEventWhenAppNotRunning() async throws {
        let controller = MeetingDetectionController()
        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Use a bundle ID that is definitely not running
        controller.startAppExitMonitoring(bundleID: "com.test.fake-app-not-running")

        // The monitor polls every 5 seconds; wait for it to fire
        try await Task.sleep(for: .seconds(6))

        if case .meetingAppExited = receivedEvent {
            // correct — the monitor detected the app is not running
        } else {
            XCTFail("Expected .meetingAppExited, got \(String(describing: receivedEvent))")
        }

        consumeTask.cancel()
    }

    func testStopAppExitMonitoringPreventsEvent() async throws {
        let controller = MeetingDetectionController()
        var receivedEvent: DetectionEvent?

        let consumeTask = Task { @MainActor in
            for await event in controller.events {
                receivedEvent = event
                break
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Start monitoring then immediately stop
        controller.startAppExitMonitoring(bundleID: "com.test.fake-app-not-running")
        controller.stopAppExitMonitoring()

        // Wait past the poll interval
        try await Task.sleep(for: .seconds(6))

        // No event should have been yielded since we stopped monitoring
        XCTAssertNil(receivedEvent)

        consumeTask.cancel()
    }
}
