import XCTest
@testable import OpenOatsKit

@MainActor
final class ExternalCommandTests: XCTestCase {

    func testQueueExternalCommandSetsProperty() {
        let coordinator = AppCoordinator()
        XCTAssertNil(coordinator.pendingExternalCommand)

        coordinator.queueExternalCommand(.startSession())
        XCTAssertNotNil(coordinator.pendingExternalCommand)
        XCTAssertEqual(coordinator.pendingExternalCommand?.command, .startSession())
    }

    func testCompleteExternalCommandClearsMatchingRequest() {
        let coordinator = AppCoordinator()
        coordinator.queueExternalCommand(.stopSession)
        let requestID = coordinator.pendingExternalCommand!.id

        coordinator.completeExternalCommand(requestID)
        XCTAssertNil(coordinator.pendingExternalCommand)
    }

    func testCompleteExternalCommandIgnoresMismatchedID() {
        let coordinator = AppCoordinator()
        coordinator.queueExternalCommand(.stopSession)

        coordinator.completeExternalCommand(UUID())
        XCTAssertNotNil(coordinator.pendingExternalCommand)
    }

    func testOpenNotesQueuesSessionSelection() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection("session_abc")
        XCTAssertEqual(coordinator.requestedNotesNavigation?.target, .session("session_abc"))
    }

    func testConsumeRequestedSessionSelectionClearsAfterRead() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection("session_abc")

        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertEqual(consumed, .session("session_abc"))
        XCTAssertNil(coordinator.requestedNotesNavigation)
    }

    func testQueueNilSessionSelectionRequestsClearSelection() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection(nil)

        XCTAssertEqual(coordinator.requestedNotesNavigation?.target, .clearSelection)
    }

    func testQueueMeetingHistoryRequestsHistoryTarget() {
        let coordinator = AppCoordinator()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        coordinator.queueMeetingHistory(event)

        XCTAssertEqual(coordinator.requestedNotesNavigation?.target, .meetingHistory(event))
    }

    func testQueueHomeMeetingHistoryRequestsHistoryTarget() {
        let coordinator = AppCoordinator()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        coordinator.queueHomeMeetingHistory(event)

        XCTAssertEqual(coordinator.requestedHomeNavigation?.target, .meetingHistory(event))
    }

    func testQueueHomeManualTranscriptRequestsManualTranscriptTarget() {
        let coordinator = AppCoordinator()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        coordinator.queueHomeManualTranscript(event)

        XCTAssertEqual(coordinator.requestedHomeNavigation?.target, .manualTranscript(event))
    }

    func testConsumeRequestedHomeNavigationClearsAfterRead() {
        let coordinator = AppCoordinator()

        coordinator.queueHomeTranscriptSessionSelection("session_abc")

        let consumed = coordinator.consumeRequestedHomeNavigation()
        XCTAssertEqual(consumed, .transcriptSession("session_abc"))
        XCTAssertNil(coordinator.requestedHomeNavigation)
    }

    func testQueueExternalStartSessionCanCarryMeetingContextAndScratchpad() {
        let coordinator = AppCoordinator()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: URL(string: "https://meet.example.com/payment-ops")
        )

        coordinator.queueExternalCommand(.startSession(calendarEvent: event, scratchpadSeed: "Follow up on fees"))

        XCTAssertEqual(
            coordinator.pendingExternalCommand?.command,
            .startSession(calendarEvent: event, scratchpadSeed: "Follow up on fees")
        )
    }

    func testConsumeRequestedSessionSelectionReturnsNilWhenEmpty() {
        let coordinator = AppCoordinator()
        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertNil(consumed)
    }

    func testConsumeRequestedHomeNavigationReturnsNilWhenEmpty() {
        let coordinator = AppCoordinator()
        let consumed = coordinator.consumeRequestedHomeNavigation()
        XCTAssertNil(consumed)
    }
}
