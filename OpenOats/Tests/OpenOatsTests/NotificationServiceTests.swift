import XCTest
@testable import OpenOatsKit

@MainActor
final class NotificationServiceTests: XCTestCase {

    func testBatchCompletedNotificationCopyUsesReTranscriptionWording() {
        XCTAssertEqual(NotificationService.batchCompletedTitle, "Re-transcription Complete")
        XCTAssertEqual(
            NotificationService.batchCompletedBody,
            "Re-transcription is complete. Your meeting transcript has been updated with higher-quality text."
        )
    }
}
