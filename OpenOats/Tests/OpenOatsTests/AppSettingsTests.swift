import XCTest
@testable import OpenOatsKit

@MainActor
final class AppSettingsTests: XCTestCase {

    // MARK: - LLMProvider

    func testLLMProviderAllCases() {
        let cases = LLMProvider.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.openRouter))
        XCTAssertTrue(cases.contains(.ollama))
        XCTAssertTrue(cases.contains(.mlx))
    }

    func testLLMProviderDisplayNames() {
        XCTAssertEqual(LLMProvider.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(LLMProvider.ollama.displayName, "Ollama")
        XCTAssertEqual(LLMProvider.mlx.displayName, "MLX")
    }

    func testLLMProviderRawValues() {
        XCTAssertEqual(LLMProvider.openRouter.rawValue, "openRouter")
        XCTAssertEqual(LLMProvider.ollama.rawValue, "ollama")
        XCTAssertEqual(LLMProvider.mlx.rawValue, "mlx")
    }

    func testLLMProviderIdentifiable() {
        XCTAssertEqual(LLMProvider.openRouter.id, "openRouter")
        XCTAssertEqual(LLMProvider.ollama.id, "ollama")
    }

    func testLLMProviderRoundTripFromRawValue() {
        for provider in LLMProvider.allCases {
            let restored = LLMProvider(rawValue: provider.rawValue)
            XCTAssertEqual(restored, provider)
        }
    }

    // MARK: - TranscriptionModel

    func testTranscriptionModelAllCases() {
        let cases = TranscriptionModel.allCases
        XCTAssertEqual(cases.count, 5)
    }

    func testTranscriptionModelDisplayNames() {
        XCTAssertEqual(TranscriptionModel.parakeetV2.displayName, "Parakeet TDT v2")
        XCTAssertEqual(TranscriptionModel.parakeetV3.displayName, "Parakeet TDT v3")
        XCTAssertEqual(TranscriptionModel.qwen3ASR06B.displayName, "Qwen3 ASR 0.6B")
        XCTAssertEqual(TranscriptionModel.whisperBase.displayName, "Whisper Base")
        XCTAssertEqual(TranscriptionModel.whisperSmall.displayName, "Whisper Small")
    }

    func testTranscriptionModelRoundTripFromRawValue() {
        for model in TranscriptionModel.allCases {
            let restored = TranscriptionModel(rawValue: model.rawValue)
            XCTAssertEqual(restored, model)
        }
    }

    func testTranscriptionModelSupportsExplicitLanguageHint() {
        XCTAssertTrue(TranscriptionModel.qwen3ASR06B.supportsExplicitLanguageHint)
        XCTAssertFalse(TranscriptionModel.parakeetV2.supportsExplicitLanguageHint)
        XCTAssertFalse(TranscriptionModel.parakeetV3.supportsExplicitLanguageHint)
        XCTAssertFalse(TranscriptionModel.whisperBase.supportsExplicitLanguageHint)
        XCTAssertFalse(TranscriptionModel.whisperSmall.supportsExplicitLanguageHint)
    }

    func testTranscriptionModelWhisperVariant() {
        XCTAssertNotNil(TranscriptionModel.whisperBase.whisperVariant)
        XCTAssertNotNil(TranscriptionModel.whisperSmall.whisperVariant)
        XCTAssertNil(TranscriptionModel.parakeetV2.whisperVariant)
        XCTAssertNil(TranscriptionModel.parakeetV3.whisperVariant)
        XCTAssertNil(TranscriptionModel.qwen3ASR06B.whisperVariant)
    }

    func testTranscriptionModelDownloadPromptNotEmpty() {
        for model in TranscriptionModel.allCases {
            XCTAssertFalse(model.downloadPrompt.isEmpty, "\(model) should have a download prompt")
        }
    }

    func testTranscriptionModelLocaleFieldTitle() {
        XCTAssertEqual(TranscriptionModel.qwen3ASR06B.localeFieldTitle, "Language Hint")
        XCTAssertEqual(TranscriptionModel.parakeetV2.localeFieldTitle, "Locale")
        XCTAssertEqual(TranscriptionModel.whisperBase.localeFieldTitle, "Locale")
    }

    // MARK: - EmbeddingProvider

    func testEmbeddingProviderAllCases() {
        let cases = EmbeddingProvider.allCases
        XCTAssertEqual(cases.count, 3)
    }

    func testEmbeddingProviderDisplayNames() {
        XCTAssertEqual(EmbeddingProvider.voyageAI.displayName, "Voyage AI")
        XCTAssertEqual(EmbeddingProvider.ollama.displayName, "Ollama")
        XCTAssertEqual(EmbeddingProvider.openAICompatible.displayName, "OpenAI Compatible")
    }

    func testEmbeddingProviderRoundTrip() {
        for provider in EmbeddingProvider.allCases {
            let restored = EmbeddingProvider(rawValue: provider.rawValue)
            XCTAssertEqual(restored, provider)
        }
    }

    // MARK: - AppSettings Defaults

    func testAppSettingsDefaultTranscriptionLocale() {
        let settings = AppSettings()
        // Default locale should be en-US unless previously set
        XCTAssertFalse(settings.transcriptionLocale.isEmpty)
    }

    func testAppSettingsLocaleProperty() {
        let settings = AppSettings()
        let locale = settings.locale
        XCTAssertFalse(locale.identifier.isEmpty)
    }

    func testAppSettingsKbFolderURLWhenEmpty() {
        let settings = AppSettings()
        let originalPath = settings.kbFolderPath
        settings.kbFolderPath = ""
        XCTAssertNil(settings.kbFolderURL)
        settings.kbFolderPath = originalPath
    }

    func testAppSettingsKbFolderURLWhenSet() {
        let settings = AppSettings()
        let originalPath = settings.kbFolderPath
        settings.kbFolderPath = "/tmp/test-kb"
        XCTAssertNotNil(settings.kbFolderURL)
        XCTAssertEqual(settings.kbFolderURL?.path, "/tmp/test-kb")
        settings.kbFolderPath = originalPath
    }
}
