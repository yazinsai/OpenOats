import XCTest
@testable import OpenOatsKit

final class RecommendationEngineTests: XCTestCase {
    private func makeSnapshot(
        ram: UInt64 = 16 * 1024 * 1024 * 1024,
        locale: String = "en-US",
        hasOpenRouterKey: Bool = false,
        hasVoyageKey: Bool = false,
        ollamaModels: Result<[String], OllamaModelFetcher.FetchError> = .failure(.networkError("not probed"))
    ) -> SetupSnapshot {
        SetupSnapshot(
            physicalMemoryBytes: ram,
            systemLocale: locale,
            audioDevices: [],
            micPermission: .notDetermined,
            modelStatuses: [:],
            hasOpenRouterKey: hasOpenRouterKey,
            hasVoyageKey: hasVoyageKey,
            existingOpenRouterKey: hasOpenRouterKey ? "sk-test" : "",
            existingVoyageKey: hasVoyageKey ? "pa-test" : "",
            ollamaResult: ollamaModels
        )
    }

    private let lowRAM: UInt64 = 8 * 1024 * 1024 * 1024
    private let highRAM: UInt64 = 16 * 1024 * 1024 * 1024

    func testTranscriptEnglish() {
        let recommendation = RecommendationEngine.recommend(
            intent: .transcribe,
            language: .english,
            privacy: .cloud,
            snapshot: makeSnapshot()
        )

        XCTAssertEqual(recommendation.profile, .transcriptEN)
        XCTAssertEqual(recommendation.transcriptionModel, .parakeetV2)
        XCTAssertEqual(recommendation.transcriptionLocale, "en-US")
        XCTAssertNil(recommendation.llmProvider)
        XCTAssertNil(recommendation.selectedModel)
        XCTAssertNil(recommendation.embeddingProvider)
        XCTAssertFalse(recommendation.suggestionPanelEnabled)
    }

    func testTranscriptMultilingual() {
        let recommendation = RecommendationEngine.recommend(
            intent: .transcribe,
            language: .multilingual,
            privacy: .local,
            snapshot: makeSnapshot(locale: "de-DE")
        )

        XCTAssertEqual(recommendation.profile, .transcriptMulti)
        XCTAssertEqual(recommendation.transcriptionModel, .parakeetV3)
        XCTAssertEqual(recommendation.transcriptionLocale, "")
    }

    func testCloudEnglish() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .cloud,
            snapshot: makeSnapshot()
        )

        XCTAssertEqual(recommendation.profile, .cloudEN)
        XCTAssertEqual(recommendation.transcriptionModel, .parakeetV2)
        XCTAssertEqual(recommendation.llmProvider, .openRouter)
        XCTAssertEqual(recommendation.selectedModel, "google/gemini-3-flash-preview")
        XCTAssertEqual(recommendation.realtimeModel, "google/gemini-3.1-flash-lite-preview")
        XCTAssertFalse(recommendation.suggestionPanelEnabled)
    }

    func testCloudEnglishFullCopilotEnablesEmbedding() {
        let recommendation = RecommendationEngine.recommend(
            intent: .fullCopilot,
            language: .english,
            privacy: .cloud,
            snapshot: makeSnapshot()
        )

        XCTAssertEqual(recommendation.profile, .cloudEN)
        XCTAssertEqual(recommendation.embeddingProvider, .voyageAI)
        XCTAssertTrue(recommendation.suggestionPanelEnabled)
        XCTAssertTrue(recommendation.detailLines.contains("Knowledge retrieval: Voyage AI"))
    }

    func testCloudMultiLowRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .multilingual,
            privacy: .cloud,
            snapshot: makeSnapshot(ram: lowRAM)
        )

        XCTAssertEqual(recommendation.profile, .cloudMulti)
        XCTAssertEqual(recommendation.transcriptionModel, .whisperSmall)
    }

    func testCloudMultiHighRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .multilingual,
            privacy: .cloud,
            snapshot: makeSnapshot(ram: highRAM)
        )

        XCTAssertEqual(recommendation.profile, .cloudMulti)
        XCTAssertEqual(recommendation.transcriptionModel, .whisperLargeV3Turbo)
    }

    func testLocalEnglishLowRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .local,
            snapshot: makeSnapshot(ram: lowRAM)
        )

        XCTAssertEqual(recommendation.profile, .localENLight)
        XCTAssertEqual(recommendation.transcriptionModel, .parakeetV2)
        XCTAssertEqual(recommendation.llmProvider, .ollama)
        XCTAssertEqual(recommendation.ollamaLLMModel, "phi3.5:3.8b-mini-q4_K_M")
        XCTAssertEqual(recommendation.ollamaBaseURL, "http://localhost:11434")
        XCTAssertEqual(recommendation.sidecastIntensity, .quiet)
    }

    func testLocalEnglishHighRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .local,
            snapshot: makeSnapshot(ram: highRAM)
        )

        XCTAssertEqual(recommendation.profile, .localENFull)
        XCTAssertEqual(recommendation.ollamaLLMModel, "qwen3:8b")
        XCTAssertEqual(recommendation.sidecastIntensity, .balanced)
    }

    func testLocalMultiLowRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .multilingual,
            privacy: .local,
            snapshot: makeSnapshot(ram: lowRAM)
        )

        XCTAssertEqual(recommendation.profile, .localMultiLight)
        XCTAssertEqual(recommendation.transcriptionModel, .whisperSmall)
        XCTAssertEqual(recommendation.ollamaLLMModel, "phi3.5:3.8b-mini-q4_K_M")
    }

    func testLocalMultiHighRAM() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .multilingual,
            privacy: .local,
            snapshot: makeSnapshot(ram: highRAM)
        )

        XCTAssertEqual(recommendation.profile, .localMultiFull)
        XCTAssertEqual(recommendation.transcriptionModel, .whisperLargeV3Turbo)
        XCTAssertEqual(recommendation.ollamaLLMModel, "qwen3:8b")
    }

    func testLocalFullCopilotIncludesEmbedModel() {
        let recommendation = RecommendationEngine.recommend(
            intent: .fullCopilot,
            language: .english,
            privacy: .local,
            snapshot: makeSnapshot(ram: highRAM)
        )

        XCTAssertEqual(recommendation.embeddingProvider, .ollama)
        XCTAssertEqual(recommendation.ollamaEmbedModel, "nomic-embed-text")
        XCTAssertTrue(recommendation.suggestionPanelEnabled)
        XCTAssertTrue(recommendation.detailLines.contains("Knowledge retrieval: nomic-embed-text via Ollama"))
    }

    func testLocalNotesDoesNotIncludeEmbedding() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .local,
            snapshot: makeSnapshot(ram: highRAM)
        )

        XCTAssertNil(recommendation.embeddingProvider)
        XCTAssertNil(recommendation.ollamaEmbedModel)
        XCTAssertFalse(recommendation.suggestionPanelEnabled)
    }

    func testRAMBoundaryJustBelow12GB() {
        XCTAssertEqual(RAMTier(physicalMemoryBytes: 11_990_000_000), .low)
    }

    func testRAMBoundaryExactly12GB() {
        XCTAssertEqual(RAMTier(physicalMemoryBytes: 12 * 1024 * 1024 * 1024), .high)
    }

    func testRequiredOllamaModelsLocalFullCopilot() {
        XCTAssertEqual(
            RecommendationEngine.requiredOllamaModels(for: .localENFull, intent: .fullCopilot),
            ["qwen3:8b", "nomic-embed-text"]
        )
    }

    func testRequiredOllamaModelsLocalNotes() {
        XCTAssertEqual(
            RecommendationEngine.requiredOllamaModels(for: .localENFull, intent: .notes),
            ["qwen3:8b"]
        )
    }

    func testTranscriptOnlyEnglishLocaleSkipsToConfirmation() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .transcribe,
            snapshot: makeSnapshot(locale: "en-US")
        )
        XCTAssertEqual(step, .confirmation)
    }

    func testTranscriptOnlyNonEnglishLocaleShowsLanguagePrivacy() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .transcribe,
            snapshot: makeSnapshot(locale: "de-DE")
        )
        XCTAssertEqual(step, .languagePrivacy)
    }

    func testNotesEnglishNoOllamaNoKeyShowsLanguagePrivacy() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .notes,
            snapshot: makeSnapshot(locale: "en-US")
        )
        XCTAssertEqual(step, .languagePrivacy)
    }

    func testNotesEnglishNoOllamaHasKeySkipsToProviderSetup() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .notes,
            snapshot: makeSnapshot(locale: "en-US", hasOpenRouterKey: true)
        )
        XCTAssertEqual(step, .providerSetup)
    }

    func testNotesEnglishOllamaNoKeySkipsToProviderSetup() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .notes,
            snapshot: makeSnapshot(locale: "en-US", ollamaModels: .success(["qwen3:8b"]))
        )
        XCTAssertEqual(step, .providerSetup)
    }

    func testNotesEnglishOllamaAndKeyShowsLanguagePrivacy() {
        let step = RecommendationEngine.nextStepAfterIntent(
            intent: .notes,
            snapshot: makeSnapshot(locale: "en-US", hasOpenRouterKey: true, ollamaModels: .success(["qwen3:8b"]))
        )
        XCTAssertEqual(step, .languagePrivacy)
    }

    func testSummaryLineCloudEnglishNotes() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .cloud,
            snapshot: makeSnapshot()
        )

        XCTAssertTrue(recommendation.summaryLine.contains("English"))
        XCTAssertTrue(recommendation.summaryLine.contains("cloud"))
    }

    func testDetailLinesIncludeTranscriptionModel() {
        let recommendation = RecommendationEngine.recommend(
            intent: .notes,
            language: .english,
            privacy: .cloud,
            snapshot: makeSnapshot()
        )

        XCTAssertTrue(recommendation.detailLines.contains(where: { $0.contains("Parakeet TDT v2") }))
    }
}
