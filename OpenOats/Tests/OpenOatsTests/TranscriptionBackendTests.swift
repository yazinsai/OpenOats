import XCTest
@testable import OpenOatsKit

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

    func testMakeBackendWhisperBase() {
        let backend = TranscriptionModel.whisperBase.makeBackend()
        XCTAssertEqual(backend.displayName, "Whisper Base")
    }

    func testMakeBackendWhisperSmall() {
        let backend = TranscriptionModel.whisperSmall.makeBackend()
        XCTAssertEqual(backend.displayName, "Whisper Small")
    }

    // MARK: - Mock Backend (protocol contract)

    func testMockBackendPrepareSetStatus() async throws {
        let mock = MockTranscriptionBackend()
        let collector = StatusCollector()
        try await mock.prepare { status in
            collector.append(status)
        }
        XCTAssertEqual(collector.statuses, ["Preparing Mock..."])
    }

    func testMockBackendTranscribeAfterPrepare() async throws {
        let mock = MockTranscriptionBackend()
        try await mock.prepare { _ in }
        let text = try await mock.transcribe([1.0, 2.0, 3.0], locale: Locale(identifier: "en-US"))
        XCTAssertEqual(text, "mock transcription")
    }

    func testMockBackendTranscribeWithoutPrepareThrows() async {
        let mock = MockTranscriptionBackend()
        do {
            _ = try await mock.transcribe([1.0], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMockBackendCheckStatus() {
        let mock = MockTranscriptionBackend()
        XCTAssertEqual(mock.checkStatus(), .ready)
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

    func testBackendStatusDownloadingEquality() {
        XCTAssertEqual(
            BackendStatus.downloading(progress: 0.5),
            BackendStatus.downloading(progress: 0.5)
        )
        XCTAssertNotEqual(
            BackendStatus.downloading(progress: 0.5),
            BackendStatus.downloading(progress: 0.7)
        )
        XCTAssertNotEqual(
            BackendStatus.downloading(progress: 0.5),
            BackendStatus.ready
        )
    }

    func testBackendStatusErrorEquality() {
        XCTAssertEqual(
            BackendStatus.error(reason: "timeout"),
            BackendStatus.error(reason: "timeout")
        )
        XCTAssertNotEqual(
            BackendStatus.error(reason: "timeout"),
            BackendStatus.error(reason: "network")
        )
        XCTAssertNotEqual(
            BackendStatus.error(reason: "timeout"),
            BackendStatus.ready
        )
    }

    // MARK: - AssemblyAIBackend

    func testAssemblyAIDisplayName() {
        let backend = AssemblyAIBackend(apiKey: "test-key")
        XCTAssertEqual(backend.displayName, "AssemblyAI")
    }

    func testAssemblyAICheckStatusAlwaysReady() {
        // checkStatus() must return .ready even with empty key
        let withKey = AssemblyAIBackend(apiKey: "test-key")
        XCTAssertEqual(withKey.checkStatus(), .ready)

        let withoutKey = AssemblyAIBackend(apiKey: "")
        XCTAssertEqual(withoutKey.checkStatus(), .ready)
    }

    func testAssemblyAITranscribeWithoutPrepareThrows() async {
        let backend = AssemblyAIBackend(apiKey: "test-key")
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - ElevenLabsScribeBackend

    func testElevenLabsDisplayName() {
        let backend = ElevenLabsScribeBackend(apiKey: "test-key")
        XCTAssertEqual(backend.displayName, "ElevenLabs Scribe")
    }

    func testElevenLabsCheckStatusAlwaysReady() {
        let withKey = ElevenLabsScribeBackend(apiKey: "test-key")
        XCTAssertEqual(withKey.checkStatus(), .ready)

        let withoutKey = ElevenLabsScribeBackend(apiKey: "")
        XCTAssertEqual(withoutKey.checkStatus(), .ready)
    }

    func testElevenLabsTranscribeWithoutPrepareThrows() async {
        let backend = ElevenLabsScribeBackend(apiKey: "test-key")
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - CohereTranscribeArabicBackend

    func testCohereTranscribeArabicDisplayName() {
        let backend = CohereTranscribeArabicBackend(apiKey: "test-key")
        XCTAssertEqual(backend.displayName, "Cohere Transcribe Arabic")
    }

    func testCohereTranscribeArabicCheckStatusAlwaysReady() {
        let withKey = CohereTranscribeArabicBackend(apiKey: "test-key")
        XCTAssertEqual(withKey.checkStatus(), .ready)

        let withoutKey = CohereTranscribeArabicBackend(apiKey: "")
        XCTAssertEqual(withoutKey.checkStatus(), .ready)
    }

    func testCohereTranscribeArabicTranscribeWithoutPrepareThrows() async {
        let backend = CohereTranscribeArabicBackend(apiKey: "test-key")
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2], locale: Locale(identifier: "ar-SA"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCohereTranscribeArabicParsesTranscriptResponse() throws {
        let json = """
        {
          "id": "tr-123",
          "status": "completed",
          "results": {
            "transcripts": [
              { "language": "ar", "text": "مرحبا يا فريق", "duration": 1.2, "offset": 0 },
              { "language": "ar", "text": "كيف الحال", "duration": 1.0, "offset": 1.2 }
            ]
          }
        }
        """

        let text = try CohereTranscribeArabicBackend.parseTranscriptResponse(Data(json.utf8))

        XCTAssertEqual(text, "مرحبا يا فريق كيف الحال")
    }

    func testCohereTranscribeArabicMultipartUsesModelLanguagePromptAndFileLast() throws {
        let body = CohereTranscribeArabicBackend.buildMultipartBody(
            boundary: "Boundary-Test",
            wavData: Data("wav-data".utf8),
            languageCode: "ar",
            prompt: "OpenOats فريق المنتج"
        )
        let bodyText = String(data: body, encoding: .utf8) ?? ""

        XCTAssertTrue(bodyText.contains("name=\"model\""))
        XCTAssertTrue(bodyText.contains("cohere-transcribe-arabic-07-2026"))
        XCTAssertTrue(bodyText.contains("name=\"language\""))
        XCTAssertTrue(bodyText.contains("\r\nar\r\n"))
        XCTAssertTrue(bodyText.contains("name=\"prompt\""))
        XCTAssertTrue(bodyText.contains("OpenOats فريق المنتج"))

        let fileRange = try XCTUnwrap(bodyText.range(of: "name=\"file\""))
        XCTAssertNil(bodyText.range(of: "name=\"model\"", range: fileRange.upperBound..<bodyText.endIndex))
        XCTAssertNil(bodyText.range(of: "name=\"language\"", range: fileRange.upperBound..<bodyText.endIndex))
        XCTAssertNil(bodyText.range(of: "name=\"prompt\"", range: fileRange.upperBound..<bodyText.endIndex))
    }

    // MARK: - TranscriptionModel cloud factory

    func testMakeBackendAssemblyAI() {
        let backend = TranscriptionModel.assemblyAI.makeBackend(apiKey: "test")
        XCTAssertEqual(backend.displayName, "AssemblyAI")
    }

    func testMakeBackendElevenLabsScribe() {
        let backend = TranscriptionModel.elevenLabsScribe.makeBackend(apiKey: "test")
        XCTAssertEqual(backend.displayName, "ElevenLabs Scribe")
    }

    func testMakeBackendCohereTranscribeArabic() {
        let backend = TranscriptionModel.cohereTranscribeArabic.makeBackend(apiKey: "test")
        XCTAssertEqual(backend.displayName, "Cohere Transcribe Arabic")
    }

    func testCloudModelsNotInBatchSuitable() {
        let batchModels = TranscriptionModel.batchSuitableModels
        XCTAssertFalse(batchModels.contains(.assemblyAI))
        XCTAssertFalse(batchModels.contains(.elevenLabsScribe))
        XCTAssertFalse(batchModels.contains(.cohereTranscribeArabic))
    }

    func testIsCloudProperty() {
        // Cloud models
        XCTAssertTrue(TranscriptionModel.assemblyAI.isCloud)
        XCTAssertTrue(TranscriptionModel.elevenLabsScribe.isCloud)
        XCTAssertTrue(TranscriptionModel.cohereTranscribeArabic.isCloud)
        // Local models
        XCTAssertFalse(TranscriptionModel.parakeetV2.isCloud)
        XCTAssertFalse(TranscriptionModel.parakeetV3.isCloud)
        XCTAssertFalse(TranscriptionModel.qwen3ASR06B.isCloud)
        XCTAssertFalse(TranscriptionModel.whisperBase.isCloud)
        XCTAssertFalse(TranscriptionModel.whisperSmall.isCloud)
        XCTAssertFalse(TranscriptionModel.whisperLargeV3Turbo.isCloud)
    }
}

// MARK: - Test Helpers

private final class StatusCollector: @unchecked Sendable {
    var statuses: [String] = []
    func append(_ status: String) { statuses.append(status) }
}

// MARK: - Mock Backend

private final class MockTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Mock"
    private var prepared = false

    func checkStatus() -> BackendStatus { .ready }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus("Preparing Mock...")
        prepared = true
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }
        return "mock transcription"
    }
}
