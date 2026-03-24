import XCTest
@testable import OpenOatsKit

@MainActor
final class SettingsStoreTests: XCTestCase {

    /// Build a SettingsStore backed by an ephemeral UserDefaults suite.
    private func makeStore(
        defaults: UserDefaults? = nil,
        secretStore: AppSecretStore = .ephemeral
    ) -> SettingsStore {
        let suite = defaults ?? {
            let name = "com.openoats.test.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return d
        }()

        let storage = SettingsStorage(
            defaults: suite,
            secretStore: secretStore,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SettingsStoreTests"),
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    // MARK: - AI Settings Group

    func testDefaultLLMProvider() {
        let store = makeStore()
        XCTAssertEqual(store.llmProvider, .openRouter)
    }

    func testLLMProviderRoundTrip() {
        let store = makeStore()
        store.llmProvider = .ollama
        XCTAssertEqual(store.llmProvider, .ollama)
    }

    func testDefaultSelectedModel() {
        let store = makeStore()
        XCTAssertEqual(store.selectedModel, "google/gemini-3-flash-preview")
    }

    func testSelectedModelRoundTrip() {
        let store = makeStore()
        store.selectedModel = "anthropic/claude-4-sonnet"
        XCTAssertEqual(store.selectedModel, "anthropic/claude-4-sonnet")
    }

    func testDefaultEmbeddingProvider() {
        let store = makeStore()
        XCTAssertEqual(store.embeddingProvider, .voyageAI)
    }

    func testDefaultSuggestionVerbosity() {
        let store = makeStore()
        XCTAssertEqual(store.suggestionVerbosity, .quiet)
    }

    func testSuggestionVerbosityRoundTrip() {
        let store = makeStore()
        store.suggestionVerbosity = .eager
        XCTAssertEqual(store.suggestionVerbosity, .eager)
    }

    func testDefaultOllamaBaseURL() {
        let store = makeStore()
        XCTAssertEqual(store.ollamaBaseURL, "http://localhost:11434")
    }

    func testDefaultOllamaLLMModel() {
        let store = makeStore()
        XCTAssertEqual(store.ollamaLLMModel, "qwen3:8b")
    }

    func testDefaultMlxModel() {
        let store = makeStore()
        XCTAssertEqual(store.mlxModel, "mlx-community/Llama-3.2-3B-Instruct-4bit")
    }

    func testDefaultEnableTranscriptRefinement() {
        let store = makeStore()
        XCTAssertFalse(store.enableTranscriptRefinement)
    }

    func testEnableTranscriptRefinementRoundTrip() {
        let store = makeStore()
        store.enableTranscriptRefinement = true
        XCTAssertTrue(store.enableTranscriptRefinement)
    }

    // MARK: - Capture Settings Group

    func testDefaultInputDeviceID() {
        let store = makeStore()
        XCTAssertEqual(store.inputDeviceID, 0)
    }

    func testDefaultTranscriptionModel() {
        let store = makeStore()
        XCTAssertEqual(store.transcriptionModel, .parakeetV2)
    }

    func testTranscriptionModelRoundTrip() {
        let store = makeStore()
        store.transcriptionModel = .whisperSmall
        XCTAssertEqual(store.transcriptionModel, .whisperSmall)
    }

    func testDefaultTranscriptionLocale() {
        let store = makeStore()
        XCTAssertEqual(store.transcriptionLocale, "en-US")
    }

    func testDefaultSaveAudioRecording() {
        let store = makeStore()
        XCTAssertFalse(store.saveAudioRecording)
    }

    func testDefaultEnableEchoCancellation() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.enableEchoCancellation)
    }

    func testDefaultEnableBatchRefinement() {
        let store = makeStore()
        // Defaults to false when key never set
        XCTAssertFalse(store.enableBatchRefinement)
    }

    func testDefaultBatchTranscriptionModel() {
        let store = makeStore()
        XCTAssertEqual(store.batchTranscriptionModel, .whisperLargeV3Turbo)
    }

    func testDefaultEnableDiarization() {
        let store = makeStore()
        XCTAssertFalse(store.enableDiarization)
    }

    func testDiarizationVariantRoundTrip() {
        let store = makeStore()
        store.diarizationVariant = .ami
        XCTAssertEqual(store.diarizationVariant, .ami)
    }

    // MARK: - Detection Settings Group

    func testDefaultMeetingAutoDetect() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.meetingAutoDetectEnabled)
    }

    func testMeetingAutoDetectRoundTrip() {
        let store = makeStore()
        store.meetingAutoDetectEnabled = false
        XCTAssertFalse(store.meetingAutoDetectEnabled)
    }

    func testDefaultSilenceTimeoutMinutes() {
        let store = makeStore()
        XCTAssertEqual(store.silenceTimeoutMinutes, 15)
    }

    func testSilenceTimeoutMinutesRoundTrip() {
        let store = makeStore()
        store.silenceTimeoutMinutes = 30
        XCTAssertEqual(store.silenceTimeoutMinutes, 30)
    }

    func testDefaultCustomMeetingAppBundleIDs() {
        let store = makeStore()
        XCTAssertEqual(store.customMeetingAppBundleIDs, [])
    }

    func testCustomMeetingAppBundleIDsRoundTrip() {
        let store = makeStore()
        store.customMeetingAppBundleIDs = ["com.example.app"]
        XCTAssertEqual(store.customMeetingAppBundleIDs, ["com.example.app"])
    }

    func testDefaultDetectionLogEnabled() {
        let store = makeStore()
        XCTAssertFalse(store.detectionLogEnabled)
    }

    // MARK: - Privacy Settings Group

    func testDefaultHasAcknowledgedRecordingConsent() {
        let store = makeStore()
        XCTAssertFalse(store.hasAcknowledgedRecordingConsent)
    }

    func testHasAcknowledgedRecordingConsentRoundTrip() {
        let store = makeStore()
        store.hasAcknowledgedRecordingConsent = true
        XCTAssertTrue(store.hasAcknowledgedRecordingConsent)
    }

    func testDefaultHideFromScreenShare() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.hideFromScreenShare)
    }

    // MARK: - UI Settings Group

    func testDefaultShowLiveTranscript() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.showLiveTranscript)
    }

    func testShowLiveTranscriptRoundTrip() {
        let store = makeStore()
        store.showLiveTranscript = false
        XCTAssertFalse(store.showLiveTranscript)
    }

    func testKbFolderURLWhenEmpty() {
        let store = makeStore()
        XCTAssertNil(store.kbFolderURL)
    }

    func testKbFolderURLWhenSet() {
        let store = makeStore()
        store.kbFolderPath = "/tmp/test-kb"
        XCTAssertEqual(store.kbFolderURL?.path, "/tmp/test-kb")
    }

    func testLocaleProperty() {
        let store = makeStore()
        XCTAssertEqual(store.locale.identifier, "en-US")
    }

    func testTranscriptionModelDisplay() {
        let store = makeStore()
        XCTAssertEqual(store.transcriptionModelDisplay, "Parakeet TDT v2")
    }

    // MARK: - Active Model Display

    func testActiveModelDisplayOpenRouter() {
        let store = makeStore()
        store.llmProvider = .openRouter
        store.selectedModel = "google/gemini-3-flash-preview"
        XCTAssertEqual(store.activeModelDisplay, "gemini-3-flash-preview")
    }

    func testActiveModelDisplayOllama() {
        let store = makeStore()
        store.llmProvider = .ollama
        store.ollamaLLMModel = "qwen3:8b"
        XCTAssertEqual(store.activeModelDisplay, "qwen3:8b")
    }

    func testActiveModelDisplayMLX() {
        let store = makeStore()
        store.llmProvider = .mlx
        store.mlxModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        XCTAssertEqual(store.activeModelDisplay, "Llama-3.2-3B-Instruct-4bit")
    }

    // MARK: - Persistence via UserDefaults

    func testPersistenceAcrossInstances() {
        let suiteName = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store1 = makeStore(defaults: defaults)
        store1.llmProvider = .mlx
        store1.silenceTimeoutMinutes = 42
        store1.transcriptionModel = .qwen3ASR06B

        // Create a second store from the same defaults
        let store2 = makeStore(defaults: defaults)
        XCTAssertEqual(store2.llmProvider, .mlx)
        XCTAssertEqual(store2.silenceTimeoutMinutes, 42)
        XCTAssertEqual(store2.transcriptionModel, .qwen3ASR06B)
    }

    // MARK: - AppSettings Typealias Compatibility

    func testTypealiasCompiles() {
        // Verify that AppSettings typealias resolves to SettingsStore
        let _: AppSettings.Type = SettingsStore.self
    }

    // MARK: - AppSettingsStorage Typealias Compatibility

    func testStorageTypealiasCompiles() {
        let _: AppSettingsStorage.Type = SettingsStorage.self
    }
}
