import XCTest
@testable import OpenOatsKit

final class MacOSCompatibilityTests: XCTestCase {
    func testSonomaKeepsSupportedModelsButExcludesQwen3() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        for model in TranscriptionModel.allCases {
            XCTAssertEqual(model.isSupported(on: sonoma), model != .qwen3ASR06B, model.rawValue)
        }
    }

    func testSequoiaAndLaterKeepEveryModel() {
        for major in [15, 26] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            XCTAssertTrue(TranscriptionModel.allCases.allSatisfy { $0.isSupported(on: version) })
        }
    }

    func testLiveAndBatchPickersOnlyOfferAvailableBackends() {
        XCTAssertTrue(TranscriptionModel.availableCases.allSatisfy(\.isAvailable))
        XCTAssertTrue(TranscriptionModel.batchSuitableModels.allSatisfy(\.isAvailable))
        XCTAssertEqual(TranscriptionModel.availableCases.contains(.qwen3ASR06B),
                       TranscriptionModel.qwen3ASR06B.isAvailable)
        XCTAssertTrue(TranscriptionModel.availableCases.contains(.parakeetV2))
        XCTAssertTrue(TranscriptionModel.batchSuitableModels.contains(.whisperLargeV3Turbo))
    }
}
