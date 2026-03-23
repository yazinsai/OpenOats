import XCTest
@testable import OpenOatsKit

@MainActor
final class ExternalCommandTests: XCTestCase {

    func testQueueExternalCommandSetsProperty() {
        let coordinator = AppCoordinator()
        XCTAssertNil(coordinator.pendingExternalCommand)

        coordinator.queueExternalCommand(.startSession)
        XCTAssertNotNil(coordinator.pendingExternalCommand)
        XCTAssertEqual(coordinator.pendingExternalCommand?.command, .startSession)
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
        XCTAssertEqual(coordinator.requestedSessionSelectionID, "session_abc")
    }

    func testConsumeRequestedSessionSelectionClearsAfterRead() {
        let coordinator = AppCoordinator()
        coordinator.queueSessionSelection("session_abc")

        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertEqual(consumed, "session_abc")
        XCTAssertNil(coordinator.requestedSessionSelectionID)
    }

    func testConsumeRequestedSessionSelectionReturnsNilWhenEmpty() {
        let coordinator = AppCoordinator()
        let consumed = coordinator.consumeRequestedSessionSelection()
        XCTAssertNil(consumed)
    }
}
