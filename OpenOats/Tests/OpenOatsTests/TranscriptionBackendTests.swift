import XCTest
@testable import OpenOats

final class TranscriptionBackendTests: XCTestCase {

    // MARK: - ParakeetBackend

    func testParakeetV2DisplayName() {
        let backend = ParakeetBackend(version: .v2)
        XCTAssertEqual(backend.displayName, "Parakeet TDT v2")
    }

    func testParakeetV3DisplayName() {
        let backend = ParakeetBackend(version: .v3)
        XCTAssertEqual(backend.displayName, "Parakeet TDT v3")
    }

    func testParakeetCheckStatusReturnsNeedsDownloadOrReady() {
        let backend = ParakeetBackend(version: .v3)
        let status = backend.checkStatus()
        switch status {
        case .ready, .needsDownload:
            break
        default:
            XCTFail("Expected .ready or .needsDownload, got \(status)")
        }
    }

    func testParakeetTranscribeWithoutPrepareThrows() async {
        let backend = ParakeetBackend(version: .v3)
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Qwen3Backend

    func testQwen3DisplayName() {
        let backend = Qwen3Backend()
        XCTAssertEqual(backend.displayName, "Qwen3 ASR 0.6B")
    }

    func testQwen3CheckStatusReturnsNeedsDownloadOrReady() {
        let backend = Qwen3Backend()
        let status = backend.checkStatus()
        switch status {
        case .ready, .needsDownload:
            break
        default:
            XCTFail("Expected .ready or .needsDownload, got \(status)")
        }
    }

    func testQwen3TranscribeWithoutPrepareThrows() async {
        let backend = Qwen3Backend()
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - TranscriptionModel factory

    func testMakeBackendParakeetV2() {
        let backend = TranscriptionModel.parakeetV2.makeBackend()
        XCTAssertEqual(backend.displayName, "Parakeet TDT v2")
    }

    func testMakeBackendParakeetV3() {
        let backend = TranscriptionModel.parakeetV3.makeBackend()
        XCTAssertEqual(backend.displayName, "Parakeet TDT v3")
    }

    func testMakeBackendQwen3() {
        let backend = TranscriptionModel.qwen3ASR06B.makeBackend()
        XCTAssertEqual(backend.displayName, "Qwen3 ASR 0.6B")
    }

    // MARK: - BackendStatus

    func testBackendStatusEquality() {
        XCTAssertEqual(BackendStatus.ready, BackendStatus.ready)
        XCTAssertNotEqual(BackendStatus.ready, BackendStatus.needsDownload(prompt: "test"))
        XCTAssertEqual(
            BackendStatus.needsDownload(prompt: "a"),
            BackendStatus.needsDownload(prompt: "a")
        )
    }
}
