import XCTest
@testable import OpenOatsKit

final class MeetingStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetadata(
        title: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> MeetingMetadata {
        MeetingMetadata(
            detectionContext: nil,
            calendarEvent: nil,
            title: title,
            startedAt: startedAt,
            endedAt: nil
        )
    }

    private func makeMetadataWithApp(
        bundleID: String = "us.zoom.xos",
        name: String = "Zoom"
    ) -> MeetingMetadata {
        let app = MeetingApp(bundleID: bundleID, name: name)
        let signal = DetectionSignal.appLaunched(app)
        let ctx = DetectionContext(
            signal: signal,
            detectedAt: Date(timeIntervalSince1970: 1_000_000),
            meetingApp: app,
            calendarEvent: nil
        )
        return MeetingMetadata(
            detectionContext: ctx,
            calendarEvent: nil,
            title: nil,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: nil
        )
    }

    private func makeCalendarEvent(
        id: String = "evt-1",
        title: String = "Sprint Planning",
        startDate: Date = Date(timeIntervalSince1970: 1_000_000),
        endDate: Date = Date(timeIntervalSince1970: 1_003_600)
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            organizer: "alice@example.com",
            participants: [
                Participant(name: "Alice", email: "alice@example.com"),
                Participant(name: "Bob", email: "bob@example.com"),
            ],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/abc")
        )
    }

    // -------------------------------------------------------------------------
    // MARK: - Idle State Tests
    // -------------------------------------------------------------------------

    func testIdleIsDefault() {
        let state: MeetingState = .idle
        XCTAssertEqual(state, .idle)
    }

    func testIdleUserStartedTransitionsToRecording() {
        let meta = makeMetadata(title: "Standup")
        let next = transition(from: .idle, on: .userStarted(meta))
        if case .recording(let m) = next {
            XCTAssertEqual(m.title, "Standup")
        } else {
            XCTFail("Expected .recording, got \(next)")
        }
    }

    func testIdleUserStoppedIsNoOp() {
        let next = transition(from: .idle, on: .userStopped)
        XCTAssertEqual(next, .idle)
    }

    func testIdleUserDiscardedIsNoOp() {
        let next = transition(from: .idle, on: .userDiscarded)
        XCTAssertEqual(next, .idle)
    }

    func testIdleFinalizationCompleteIsNoOp() {
        let next = transition(from: .idle, on: .finalizationComplete)
        XCTAssertEqual(next, .idle)
    }

    func testIdleFinalizationTimeoutIsNoOp() {
        let next = transition(from: .idle, on: .finalizationTimeout)
        XCTAssertEqual(next, .idle)
    }

    // -------------------------------------------------------------------------
    // MARK: - Recording State Tests
    // -------------------------------------------------------------------------

    func testRecordingUserStoppedTransitionsToEnding() {
        let meta = makeMetadata()
        let state = MeetingState.recording(meta)
        let next = transition(from: state, on: .userStopped)
        if case .ending = next {
            // pass
        } else {
            XCTFail("Expected .ending, got \(next)")
        }
    }

    func testRecordingUserDiscardedTransitionsToIdle() {
        let meta = makeMetadata()
        let state = MeetingState.recording(meta)
        let next = transition(from: state, on: .userDiscarded)
        XCTAssertEqual(next, .idle)
    }

    func testRecordingDoubleStartIsNoOp() {
        let meta = makeMetadata(title: "First")
        let state = MeetingState.recording(meta)
        let meta2 = makeMetadata(title: "Second")
        let next = transition(from: state, on: .userStarted(meta2))
        if case .recording(let m) = next {
            XCTAssertEqual(m.title, "First", "Double start should keep original metadata")
        } else {
            XCTFail("Expected .recording, got \(next)")
        }
    }

    func testRecordingFinalizationCompleteIsNoOp() {
        let meta = makeMetadata()
        let state = MeetingState.recording(meta)
        let next = transition(from: state, on: .finalizationComplete)
        if case .recording = next {
            // pass
        } else {
            XCTFail("Expected .recording, got \(next)")
        }
    }

    func testRecordingFinalizationTimeoutIsNoOp() {
        let meta = makeMetadata()
        let state = MeetingState.recording(meta)
        let next = transition(from: state, on: .finalizationTimeout)
        if case .recording = next {
            // pass
        } else {
            XCTFail("Expected .recording, got \(next)")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Ending State Tests
    // -------------------------------------------------------------------------

    func testEndingFinalizationCompleteTransitionsToIdle() {
        let meta = makeMetadata()
        let state = MeetingState.ending(meta)
        let next = transition(from: state, on: .finalizationComplete)
        XCTAssertEqual(next, .idle)
    }

    func testEndingFinalizationTimeoutTransitionsToIdle() {
        let meta = makeMetadata()
        let state = MeetingState.ending(meta)
        let next = transition(from: state, on: .finalizationTimeout)
        XCTAssertEqual(next, .idle)
    }

    func testEndingUserStartedIsNoOp() {
        let meta = makeMetadata(title: "Ending")
        let state = MeetingState.ending(meta)
        let meta2 = makeMetadata(title: "New")
        let next = transition(from: state, on: .userStarted(meta2))
        if case .ending(let m) = next {
            XCTAssertEqual(m.title, "Ending", "Should not start new session while ending")
        } else {
            XCTFail("Expected .ending, got \(next)")
        }
    }

    func testEndingUserStoppedIsNoOp() {
        let meta = makeMetadata()
        let state = MeetingState.ending(meta)
        let next = transition(from: state, on: .userStopped)
        if case .ending = next {
            // pass
        } else {
            XCTFail("Expected .ending, got \(next)")
        }
    }

    func testEndingUserDiscardedIsNoOp() {
        let meta = makeMetadata()
        let state = MeetingState.ending(meta)
        let next = transition(from: state, on: .userDiscarded)
        if case .ending = next {
            // pass
        } else {
            XCTFail("Expected .ending, got \(next)")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Full Lifecycle Tests
    // -------------------------------------------------------------------------

    func testFullHappyPath() {
        var state: MeetingState = .idle
        let meta = makeMetadata(title: "1:1")

        // Start
        state = transition(from: state, on: .userStarted(meta))
        if case .recording = state {} else { XCTFail("Expected .recording") }

        // Stop
        state = transition(from: state, on: .userStopped)
        if case .ending = state {} else { XCTFail("Expected .ending") }

        // Finalize
        state = transition(from: state, on: .finalizationComplete)
        XCTAssertEqual(state, .idle)
    }

    func testDiscardPath() {
        var state: MeetingState = .idle
        let meta = makeMetadata()

        state = transition(from: state, on: .userStarted(meta))
        if case .recording = state {} else { XCTFail("Expected .recording") }

        state = transition(from: state, on: .userDiscarded)
        XCTAssertEqual(state, .idle)
    }

    func testTimeoutPath() {
        var state: MeetingState = .idle
        let meta = makeMetadata()

        state = transition(from: state, on: .userStarted(meta))
        state = transition(from: state, on: .userStopped)
        if case .ending = state {} else { XCTFail("Expected .ending") }

        state = transition(from: state, on: .finalizationTimeout)
        XCTAssertEqual(state, .idle)
    }

    func testMultipleSessionsSequentially() {
        var state: MeetingState = .idle

        for i in 1...3 {
            let meta = makeMetadata(title: "Session \(i)")
            state = transition(from: state, on: .userStarted(meta))
            if case .recording(let m) = state {
                XCTAssertEqual(m.title, "Session \(i)")
            } else {
                XCTFail("Expected .recording for session \(i)")
            }
            state = transition(from: state, on: .userStopped)
            state = transition(from: state, on: .finalizationComplete)
            XCTAssertEqual(state, .idle)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Metadata Preservation Tests
    // -------------------------------------------------------------------------

    func testMetadataPreservedFromRecordingToEnding() {
        let meta = makeMetadata(title: "Planning", startedAt: Date(timeIntervalSince1970: 999))
        let state = MeetingState.recording(meta)
        let next = transition(from: state, on: .userStopped)
        if case .ending(let m) = next {
            XCTAssertEqual(m.title, "Planning")
            XCTAssertEqual(m.startedAt, Date(timeIntervalSince1970: 999))
        } else {
            XCTFail("Expected .ending with metadata")
        }
    }

    func testDetectionContextPreservedInMetadata() {
        let meta = makeMetadataWithApp()
        let state = transition(from: .idle, on: .userStarted(meta))
        if case .recording(let m) = state {
            XCTAssertNotNil(m.detectionContext)
            XCTAssertEqual(m.detectionContext?.meetingApp?.bundleID, "us.zoom.xos")
        } else {
            XCTFail("Expected .recording")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - MeetingTypes Tests
    // -------------------------------------------------------------------------

    func testMeetingAppEquality() {
        let a = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let b = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        XCTAssertEqual(a, b)
    }

    func testMeetingAppInequality() {
        let a = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let b = MeetingApp(bundleID: "com.microsoft.teams2", name: "Teams")
        XCTAssertNotEqual(a, b)
    }

    func testCalendarEventIdentifiable() {
        let event = makeCalendarEvent()
        XCTAssertEqual(event.id, "evt-1")
        XCTAssertEqual(event.title, "Sprint Planning")
        XCTAssertTrue(event.isOnlineMeeting)
        XCTAssertEqual(event.participants.count, 2)
    }

    func testParticipantFields() {
        let p = Participant(name: "Alice", email: "alice@example.com")
        XCTAssertEqual(p.name, "Alice")
        XCTAssertEqual(p.email, "alice@example.com")
    }

    func testParticipantOptionalFields() {
        let p = Participant(name: nil, email: nil)
        XCTAssertNil(p.name)
        XCTAssertNil(p.email)
    }

    func testDetectionSignalManual() {
        let signal = DetectionSignal.manual
        XCTAssertEqual(signal, .manual)
    }

    func testDetectionSignalAppLaunched() {
        let app = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let signal = DetectionSignal.appLaunched(app)
        if case .appLaunched(let a) = signal {
            XCTAssertEqual(a.bundleID, "us.zoom.xos")
        } else {
            XCTFail("Expected .appLaunched")
        }
    }

    func testDetectionSignalCalendarEvent() {
        let event = makeCalendarEvent()
        let signal = DetectionSignal.calendarEvent(event)
        if case .calendarEvent(let e) = signal {
            XCTAssertEqual(e.title, "Sprint Planning")
        } else {
            XCTFail("Expected .calendarEvent")
        }
    }

    func testDetectionSignalAudioActivity() {
        let signal = DetectionSignal.audioActivity
        XCTAssertEqual(signal, .audioActivity)
    }

    func testDetectionContext() {
        let app = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let ctx = DetectionContext(
            signal: .appLaunched(app),
            detectedAt: Date(timeIntervalSince1970: 1_000_000),
            meetingApp: app,
            calendarEvent: nil
        )
        XCTAssertNotNil(ctx.meetingApp)
        XCTAssertNil(ctx.calendarEvent)
    }

    func testMeetingMetadataBasic() {
        let meta = makeMetadata(title: "Retro")
        XCTAssertEqual(meta.title, "Retro")
        XCTAssertNil(meta.endedAt)
        XCTAssertNil(meta.detectionContext)
    }

    func testMeetingMetadataWithEndDate() {
        var meta = makeMetadata()
        meta.endedAt = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNotNil(meta.endedAt)
    }

    // -------------------------------------------------------------------------
    // MARK: - Encoding / Decoding Tests
    // -------------------------------------------------------------------------

    func testMeetingAppCodable() throws {
        let app = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(MeetingApp.self, from: data)
        XCTAssertEqual(decoded, app)
    }

    func testCalendarEventCodable() throws {
        let event = makeCalendarEvent()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CalendarEvent.self, from: data)
        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.title, event.title)
        XCTAssertEqual(decoded.participants.count, event.participants.count)
    }

    func testDetectionSignalManualCodable() throws {
        let signal = DetectionSignal.manual
        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(DetectionSignal.self, from: data)
        XCTAssertEqual(decoded, signal)
    }

    func testDetectionSignalAppLaunchedCodable() throws {
        let app = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        let signal = DetectionSignal.appLaunched(app)
        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(DetectionSignal.self, from: data)
        XCTAssertEqual(decoded, signal)
    }

    func testMeetingMetadataCodable() throws {
        let meta = makeMetadataWithApp()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingMetadata.self, from: data)
        XCTAssertEqual(decoded.detectionContext?.meetingApp?.bundleID, "us.zoom.xos")
    }

    // -------------------------------------------------------------------------
    // MARK: - Edge Cases
    // -------------------------------------------------------------------------

    func testRapidStartStop() {
        var state: MeetingState = .idle
        let meta = makeMetadata()
        state = transition(from: state, on: .userStarted(meta))
        state = transition(from: state, on: .userStopped)
        state = transition(from: state, on: .finalizationComplete)
        XCTAssertEqual(state, .idle)
    }

    func testStopWhileIdleIsHarmless() {
        let state: MeetingState = .idle
        let next = transition(from: state, on: .userStopped)
        XCTAssertEqual(next, .idle)
    }

    func testDiscardWhileIdleIsHarmless() {
        let state: MeetingState = .idle
        let next = transition(from: state, on: .userDiscarded)
        XCTAssertEqual(next, .idle)
    }

    func testDoubleFinalizationIsHarmless() {
        let meta = makeMetadata()
        var state = MeetingState.ending(meta)
        state = transition(from: state, on: .finalizationComplete)
        XCTAssertEqual(state, .idle)
        // Second finalization on idle is a no-op
        state = transition(from: state, on: .finalizationComplete)
        XCTAssertEqual(state, .idle)
    }

    func testDiscardWhileEndingIsNoOp() {
        let meta = makeMetadata()
        let state = MeetingState.ending(meta)
        let next = transition(from: state, on: .userDiscarded)
        if case .ending = next {
            // Discard during finalization is ignored
        } else {
            XCTFail("Expected .ending, got \(next)")
        }
    }

    func testStartWhileEndingIsNoOp() {
        let meta = makeMetadata(title: "Old")
        let state = MeetingState.ending(meta)
        let newMeta = makeMetadata(title: "New")
        let next = transition(from: state, on: .userStarted(newMeta))
        if case .ending(let m) = next {
            XCTAssertEqual(m.title, "Old")
        } else {
            XCTFail("Expected .ending with old metadata")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - MeetingState Equatable
    // -------------------------------------------------------------------------

    func testIdleEqualsIdle() {
        XCTAssertEqual(MeetingState.idle, MeetingState.idle)
    }

    func testRecordingNotEqualToIdle() {
        let meta = makeMetadata()
        XCTAssertNotEqual(MeetingState.recording(meta), MeetingState.idle)
    }

    func testEndingNotEqualToRecording() {
        let meta = makeMetadata()
        XCTAssertNotEqual(MeetingState.ending(meta), MeetingState.recording(meta))
    }

    func testEndingNotEqualToIdle() {
        let meta = makeMetadata()
        XCTAssertNotEqual(MeetingState.ending(meta), MeetingState.idle)
    }

    // -------------------------------------------------------------------------
    // MARK: - MeetingAppEntry Tests
    // -------------------------------------------------------------------------

    func testMeetingAppEntryFields() {
        let entry = MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime")
        XCTAssertEqual(entry.bundleID, "com.apple.FaceTime")
        XCTAssertEqual(entry.displayName, "FaceTime")
    }

    func testMeetingAppEntryEquality() {
        let a = MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack")
        let b = MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack")
        XCTAssertEqual(a, b)
    }

    func testMeetingAppEntryCodable() throws {
        let entry = MeetingAppEntry(bundleID: "us.zoom.xos", displayName: "Zoom")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MeetingAppEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}
