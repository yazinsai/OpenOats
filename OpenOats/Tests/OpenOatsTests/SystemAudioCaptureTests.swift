import CoreAudio
import XCTest
@testable import OpenOatsKit

final class SystemAudioCaptureTests: XCTestCase {
    func testDeviceTapSelectsStreamAndExcludesOwnProcess() {
        let uuid = UUID()
        let description = SystemAudioCapture.makeTapDescription(
            outputUID: "test-output", excludingProcess: 123, uuid: uuid
        )
        XCTAssertEqual(description.deviceUID, "test-output")
        XCTAssertEqual(description.stream, 0)
        XCTAssertEqual(description.processes, [123])
        XCTAssertEqual(description.uuid, uuid)
        XCTAssertTrue(description.isExclusive)
        XCTAssertTrue(description.isPrivate)
        XCTAssertTrue(description.isMono)
        XCTAssertTrue(description.isMixdown)
        XCTAssertEqual(description.muteBehavior, .unmuted)
    }

    func testMissingProcessIDStillCapturesOtherProcesses() {
        let description = SystemAudioCapture.makeTapDescription(
            outputUID: "test-output", excludingProcess: nil, uuid: UUID()
        )
        XCTAssertTrue(description.processes.isEmpty)
        XCTAssertTrue(description.isExclusive)
        XCTAssertEqual(description.stream, 0)
    }

    func testUnknownTapIsRejectedEvenAfterSuccessfulCreationStatus() {
        XCTAssertFalse(SystemAudioCapture.isValidTapID(AudioObjectID(kAudioObjectUnknown)))
        XCTAssertTrue(SystemAudioCapture.isValidTapID(183))
    }
}
