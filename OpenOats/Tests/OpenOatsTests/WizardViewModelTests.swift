import XCTest
@testable import OpenOatsKit

@MainActor
final class WizardViewModelTests: XCTestCase {
    private func makeSnapshot(
        ram: UInt64 = 16 * 1024 * 1024 * 1024,
        locale: String = "en-US",
        hasOpenRouterKey: Bool = false,
        hasAssemblyAIKey: Bool = false,
        hasElevenLabsKey: Bool = false,
        hasCohereKey: Bool = false,
        hasVoyageKey: Bool = false,
        ollamaModels: Result<[String], OllamaModelFetcher.FetchError> = .failure(.networkError("no"))
    ) -> SetupSnapshot {
        SetupSnapshot(
            physicalMemoryBytes: ram,
            systemLocale: locale,
            audioDevices: [],
            micPermission: .notDetermined,
            modelStatuses: [:],
            hasOpenRouterKey: hasOpenRouterKey,
            hasVoyageKey: hasVoyageKey,
            hasAssemblyAIKey: hasAssemblyAIKey,
            hasElevenLabsKey: hasElevenLabsKey,
            hasCohereKey: hasCohereKey,
            existingOpenRouterKey: hasOpenRouterKey ? "sk-or-test" : "",
            existingVoyageKey: hasVoyageKey ? "pa-test" : "",
            existingAssemblyAIKey: hasAssemblyAIKey ? "aai-test" : "",
            existingElevenLabsKey: hasElevenLabsKey ? "xi-test" : "",
            existingCohereKey: hasCohereKey ? "co-test" : "",
            ollamaResult: ollamaModels
        )
    }

    private func makeStore() -> SettingsStore {
        let name = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("WizardViewModelTests"),
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    private func makeConfiguredVM(snapshot: SetupSnapshot? = nil) -> WizardViewModel {
        let viewModel = WizardViewModel()
        viewModel.configure(with: snapshot ?? makeSnapshot())
        return viewModel
    }

    func testInitialStep() {
        let viewModel = WizardViewModel()
        XCTAssertEqual(viewModel.currentStep, .intent)
        XCTAssertTrue(viewModel.isDetecting)
    }

    func testConfigureDisablesDetecting() {
        let viewModel = WizardViewModel()
        viewModel.configure(with: makeSnapshot())
        XCTAssertFalse(viewModel.isDetecting)
    }

    func testCannotAdvanceWithoutIntent() {
        let viewModel = makeConfiguredVM()
        XCTAssertFalse(viewModel.canAdvance)
    }

    func testCanAdvanceWithIntent() {
        let viewModel = makeConfiguredVM()
        viewModel.intent = .notes
        XCTAssertTrue(viewModel.canAdvance)
    }

    func testTranscriptEnglishSkipsToConfirmation() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot(locale: "en-US"))
        viewModel.intent = .transcribe
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .confirmation)
    }

    func testTranscriptNonEnglishGoesToLanguagePrivacy() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot(locale: "de-DE"))
        viewModel.intent = .transcribe
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .languagePrivacy)
    }

    func testNotesEnglishWithKeySkipsToProviderSetup() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot(hasOpenRouterKey: true))
        viewModel.intent = .notes
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .providerSetup)
    }

    func testNotesEnglishNoDetectionShowsLanguagePrivacy() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot())
        viewModel.intent = .notes
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .languagePrivacy)
    }

    func testGoBackReturnsToIntent() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot(locale: "de-DE"))
        viewModel.intent = .transcribe
        viewModel.advance()
        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .intent)
    }

    func testGoBackPreservesAnswers() {
        let viewModel = makeConfiguredVM(snapshot: makeSnapshot(locale: "de-DE"))
        viewModel.intent = .transcribe
        viewModel.advance()
        viewModel.language = .multilingual
        viewModel.goBack()

        XCTAssertEqual(viewModel.intent, .transcribe)
        XCTAssertEqual(viewModel.language, .multilingual)
    }

    func testRecommendationUpdatesOnIntentChange() {
        let viewModel = makeConfiguredVM()
        viewModel.intent = .transcribe
        XCTAssertEqual(viewModel.recommendation?.profile, .transcriptEN)

        viewModel.intent = .notes
        viewModel.privacy = .cloud
        XCTAssertEqual(viewModel.recommendation?.profile, .cloudEN)
    }

    func testExistingKeysPrePopulated() {
        let viewModel = WizardViewModel()
        viewModel.configure(with: makeSnapshot(
            hasOpenRouterKey: true,
            hasAssemblyAIKey: true,
            hasElevenLabsKey: true,
            hasCohereKey: true,
            hasVoyageKey: true
        ))

        XCTAssertEqual(viewModel.openRouterKeyInput, "sk-or-test")
        XCTAssertEqual(viewModel.voyageKeyInput, "pa-test")
        XCTAssertEqual(viewModel.assemblyAIKeyInput, "aai-test")
        XCTAssertEqual(viewModel.elevenLabsKeyInput, "xi-test")
        XCTAssertEqual(viewModel.cohereKeyInput, "co-test")
    }

    func testApplySettingsWritesCloudProfile() {
        let store = makeStore()
        let viewModel = makeConfiguredVM()
        viewModel.intent = .notes
        viewModel.language = .english
        viewModel.privacy = .cloud
        viewModel.assemblyAIKeyInput = "aai-new"

        viewModel.applySettings(to: store)

        XCTAssertEqual(store.transcriptionModel, .assemblyAI)
        XCTAssertEqual(store.transcriptionLocale, "en-US")
        XCTAssertEqual(store.assemblyAIApiKey, "aai-new")
        XCTAssertEqual(store.elevenLabsApiKey, "")
        XCTAssertEqual(store.llmProvider, .openRouter)
        XCTAssertEqual(store.selectedModel, "google/gemini-3-flash-preview")
        XCTAssertEqual(store.suggestionVerbosity, .balanced)
        XCTAssertEqual(store.sidebarMode, .classicSuggestions)
        XCTAssertTrue(store.meetingAutoDetectEnabled)
        XCTAssertTrue(store.hasShownAutoDetectExplanation)
        XCTAssertTrue(viewModel.isComplete)
    }

    func testApplySettingsWritesCohereForCloudMultilingualProfile() {
        let store = makeStore()
        let viewModel = makeConfiguredVM()
        viewModel.intent = .notes
        viewModel.language = .multilingual
        viewModel.privacy = .cloud
        viewModel.cohereKeyInput = "co-new"

        viewModel.applySettings(to: store)

        XCTAssertEqual(store.transcriptionModel, .cohereTranscribeArabic)
        XCTAssertEqual(store.transcriptionLocale, "ar")
        XCTAssertEqual(store.cohereApiKey, "co-new")
        XCTAssertEqual(store.assemblyAIApiKey, "")
        XCTAssertEqual(store.elevenLabsApiKey, "")
    }

    func testApplySettingsLocalProfile() {
        let store = makeStore()
        let viewModel = makeConfiguredVM()
        viewModel.intent = .fullCopilot
        viewModel.language = .english
        viewModel.privacy = .local

        viewModel.applySettings(to: store)

        XCTAssertEqual(store.llmProvider, .ollama)
        XCTAssertEqual(store.ollamaLLMModel, "qwen3:8b")
        XCTAssertEqual(store.ollamaBaseURL, "http://localhost:11434")
        XCTAssertEqual(store.ollamaEmbedModel, "nomic-embed-text")
        XCTAssertEqual(store.embeddingProvider, .ollama)
        XCTAssertTrue(store.suggestionPanelEnabled)
    }

    func testApplySettingsTranscriptOnly() {
        let store = makeStore()
        let viewModel = makeConfiguredVM()
        viewModel.intent = .transcribe
        viewModel.language = .english

        viewModel.applySettings(to: store)

        XCTAssertEqual(store.transcriptionModel, .parakeetV2)
        XCTAssertFalse(store.suggestionPanelEnabled)
        XCTAssertTrue(store.meetingAutoDetectEnabled)
    }

    func testApplySettingsClearsStaleCloudKeys() {
        let store = makeStore()
        store.openRouterApiKey = "old-key"
        store.voyageApiKey = "old-voyage"
        store.assemblyAIApiKey = "old-aai"
        store.elevenLabsApiKey = "old-xi"
        store.cohereApiKey = "old-co"

        let viewModel = makeConfiguredVM()
        viewModel.intent = .notes
        viewModel.language = .english
        viewModel.privacy = .local

        viewModel.applySettings(to: store)

        XCTAssertEqual(store.openRouterApiKey, "")
        XCTAssertEqual(store.voyageApiKey, "")
        XCTAssertEqual(store.assemblyAIApiKey, "")
        XCTAssertEqual(store.elevenLabsApiKey, "")
        XCTAssertEqual(store.cohereApiKey, "")
    }

    func testReconfigurationSeedsCurrentSettings() {
        let store = makeStore()
        store.llmProvider = .ollama
        store.suggestionPanelEnabled = true
        store.transcriptionModel = .whisperSmall
        store.transcriptionLocale = ""

        let viewModel = WizardViewModel()
        viewModel.configure(with: makeSnapshot(), currentSettings: store, isReconfiguration: true)

        XCTAssertEqual(viewModel.intent, .fullCopilot)
        XCTAssertEqual(viewModel.language, .multilingual)
        XCTAssertEqual(viewModel.privacy, .local)
    }

    func testConfirmationCanAdvanceWithMicAuthorized() {
        let viewModel = makeConfiguredVM()
        viewModel.intent = .transcribe
        viewModel.advance()

        XCTAssertEqual(viewModel.currentStep, .confirmation)
        XCTAssertFalse(viewModel.canAdvance)

        viewModel.micPermission = .authorized
        XCTAssertTrue(viewModel.canAdvance)
    }
}
