import XCTest
@testable import OpenOatsKit

@MainActor
final class SettingsStoreTests: XCTestCase {
    private final class LoadTracker: @unchecked Sendable {
        var loadedKeys: [String] = []
        var savedValues: [String: String] = [:]
    }

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

    func testOpenRouterApiKeyAutoTrimsWhitespace() {
        let store = makeStore()
        store.openRouterApiKey = "  sk-or-v1-abc123  \n"
        XCTAssertEqual(store.openRouterApiKey, "sk-or-v1-abc123")
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

    func testVoyageApiKeyAutoTrimsWhitespace() {
        let store = makeStore()
        store.voyageApiKey = "  pa-abc123  \t"
        XCTAssertEqual(store.voyageApiKey, "pa-abc123")
    }

    func testDefaultSuggestionVerbosity() {
        let store = makeStore()
        XCTAssertEqual(store.suggestionVerbosity, .quiet)
    }

    func testDefaultSidebarMode() {
        let store = makeStore()
        XCTAssertEqual(store.sidebarMode, .classicSuggestions)
    }

    func testSidebarModeRoundTrip() {
        let store = makeStore()
        store.sidebarMode = .sidecast
        XCTAssertEqual(store.sidebarMode, .sidecast)
    }

    func testDefaultSidecastIntensity() {
        let store = makeStore()
        XCTAssertEqual(store.sidecastIntensity, .balanced)
    }

    func testDefaultSidecastPersonas() {
        let store = makeStore()
        XCTAssertEqual(store.sidecastPersonas.count, 4)
        XCTAssertEqual(store.enabledSidecastPersonas.count, 4)
        XCTAssertEqual(store.sidecastPersonas.first?.name, "The Checker")
    }

    func testSidecastPersonasRoundTrip() {
        let store = makeStore()
        store.sidecastPersonas = [
            SidecastPersona(
                name: "The Wire",
                subtitle: "Fresh updates",
                prompt: "Surface only truly new developments.",
                avatarSymbol: "dot.radiowaves.left.and.right",
                avatarTint: .blue,
                verbosity: .short,
                cadence: .normal,
                evidencePolicy: .preferred
            ),
        ]

        XCTAssertEqual(store.sidecastPersonas.count, 1)
        XCTAssertEqual(store.sidecastPersonas.first?.name, "The Wire")
        XCTAssertEqual(store.sidecastPersonas.first?.avatarSymbol, "dot.radiowaves.left.and.right")
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

    func testDefaultEnableLiveTranscriptCleanup() {
        let store = makeStore()
        XCTAssertFalse(store.enableLiveTranscriptCleanup)
    }

    func testEnableLiveTranscriptCleanupRoundTrip() {
        let store = makeStore()
        store.enableLiveTranscriptCleanup = true
        XCTAssertTrue(store.enableLiveTranscriptCleanup)
    }

    func testEnableLiveTranscriptCleanupDualWritesLegacyKey() {
        let suiteName = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = makeStore(defaults: defaults)
        store.enableLiveTranscriptCleanup = true

        XCTAssertEqual(defaults.bool(forKey: "enableLiveTranscriptCleanup"), true)
        XCTAssertEqual(defaults.bool(forKey: "enableTranscriptRefinement"), true)

        let reopened = makeStore(defaults: defaults)
        XCTAssertTrue(reopened.enableLiveTranscriptCleanup)
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

    func testDefaultEnableBatchRetranscription() {
        let store = makeStore()
        // Defaults to false when key never set
        XCTAssertFalse(store.enableBatchRetranscription)
    }

    func testEnableBatchRetranscriptionDualWritesLegacyKey() {
        let suiteName = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = makeStore(defaults: defaults)
        store.enableBatchRetranscription = true

        XCTAssertEqual(defaults.bool(forKey: "enableBatchRetranscription"), true)
        XCTAssertEqual(defaults.bool(forKey: "enableBatchRefinement"), true)

        let reopened = makeStore(defaults: defaults)
        XCTAssertTrue(reopened.enableBatchRetranscription)
    }

    func testDiagnosticLoggingRoundTrip() {
        let store = makeStore()
        XCTAssertFalse(store.diagnosticLoggingEnabled)

        store.diagnosticLoggingEnabled = true
        XCTAssertTrue(store.diagnosticLoggingEnabled)
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

    func testDefaultShareCalendarContextWithCloudNotes() {
        let store = makeStore()
        XCTAssertFalse(store.shareCalendarContextWithCloudNotes)
    }

    func testShareCalendarContextWithCloudNotesRoundTrip() {
        let store = makeStore()
        store.shareCalendarContextWithCloudNotes = true
        XCTAssertTrue(store.shareCalendarContextWithCloudNotes)
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

    func testDefaultNotesFolders() {
        let store = makeStore()
        XCTAssertEqual(store.notesFolders, [])
    }

    func testNotesFoldersRoundTrip() {
        let store = makeStore()
        store.notesFolders = [
            NotesFolderDefinition(path: "Work/1:1s", color: .orange),
            NotesFolderDefinition(path: "Personal", color: .purple),
        ]
        XCTAssertEqual(store.notesFolders.map(\.path), ["Personal", "Work/1:1s"])
        XCTAssertEqual(store.notesFolders.map(\.color), [.purple, .orange])
    }

    func testNotesFoldersNormalizeAndDedupePaths() {
        let store = makeStore()
        store.notesFolders = [
            NotesFolderDefinition(path: " Work // 1:1s / Bertie / ", color: .teal),
            NotesFolderDefinition(path: "work/1:1s/bertie", color: .orange),
            NotesFolderDefinition(path: " / ./ ", color: .purple),
        ]
        XCTAssertEqual(store.notesFolders.map(\.path), ["Work/1:1s/Bertie"])
        XCTAssertEqual(store.notesFolders.map(\.color), [.teal])
    }

    func testMeetingPrepNotesRoundTripAndClear() {
        let store = makeStore()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        XCTAssertEqual(store.meetingPrepNotes(for: event), "")

        store.setMeetingPrepNotes("Follow up on merchant fees", for: event)
        XCTAssertEqual(store.meetingPrepNotes(for: event), "Follow up on merchant fees")

        store.setMeetingPrepNotes("   ", for: event)
        XCTAssertEqual(store.meetingPrepNotes(for: event), "")
        XCTAssertEqual(store.meetingPrepNotesByKey, [:])
    }

    func testMeetingHistoryAliasesNormalizeAndCanonicalizePrepNotes() {
        let store = makeStore()
        store.meetingHistoryAliasesByKey = [
            " Payment Ops ": "payment ops merchant standup",
            "payment ops merchant standup": "payment ops merchant standup",
            "": "ignored",
        ]

        XCTAssertEqual(
            store.meetingHistoryAliasesByKey,
            ["payment ops": "payment ops merchant standup"]
        )

        let renamedEvent = CalendarEvent(
            id: "evt-renamed",
            title: "Payment Ops / Merchant standup",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
        let legacyEvent = CalendarEvent(
            id: "evt-legacy",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        store.setMeetingPrepNotes("Carry this forward", for: renamedEvent)

        XCTAssertEqual(store.meetingPrepNotes(for: legacyEvent), "Carry this forward")
        XCTAssertEqual(
            store.canonicalMeetingHistoryKey(for: legacyEvent),
            MeetingHistoryResolver.historyKey(for: renamedEvent)
        )
    }

    func testMeetingFamilyTemplatePreferenceCanonicalizesThroughAliases() {
        let store = makeStore()
        store.meetingHistoryAliasesByKey = [
            "payment ops": "payment ops merchant standup",
        ]

        let renamedEvent = CalendarEvent(
            id: "evt-renamed",
            title: "Payment Ops / Merchant standup",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
        let legacyEvent = CalendarEvent(
            id: "evt-legacy",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        store.setMeetingFamilyTemplatePreference(TemplateStore.standUpID, for: renamedEvent)

        XCTAssertEqual(
            store.meetingFamilyPreferences(for: legacyEvent)?.templateID,
            TemplateStore.standUpID
        )
        XCTAssertEqual(
            store.meetingFamilyPreferencesByKey[MeetingHistoryResolver.historyKey(for: renamedEvent)]?.templateID,
            TemplateStore.standUpID
        )

        store.setMeetingFamilyTemplatePreference(nil, for: legacyEvent)
        XCTAssertNil(store.meetingFamilyPreferences(for: renamedEvent))
        XCTAssertTrue(store.meetingFamilyPreferencesByKey.isEmpty)
    }

    func testMeetingFamilyFolderPreferenceCanonicalizesThroughAliases() {
        let store = makeStore()
        store.meetingHistoryAliasesByKey = [
            "payment ops": "payment ops merchant standup",
        ]

        let renamedEvent = CalendarEvent(
            id: "evt-renamed",
            title: "Payment Ops / Merchant standup",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )
        let legacyEvent = CalendarEvent(
            id: "evt-legacy",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        store.setMeetingFamilyFolderPreference("Work/Payments", for: renamedEvent)

        XCTAssertEqual(
            store.meetingFamilyPreferences(for: legacyEvent)?.folderPath,
            "Work/Payments"
        )
        XCTAssertEqual(
            store.meetingFamilyPreferencesByKey[MeetingHistoryResolver.historyKey(for: renamedEvent)]?.folderPath,
            "Work/Payments"
        )

        store.setMeetingFamilyFolderPreference(nil, for: legacyEvent)
        XCTAssertNil(store.meetingFamilyPreferences(for: renamedEvent))
        XCTAssertTrue(store.meetingFamilyPreferencesByKey.isEmpty)
    }

    func testMeetingFamilyFolderPreferenceRejectsPathsDeeperThanOneSubfolder() {
        let store = makeStore()
        let event = CalendarEvent(
            id: "evt",
            title: "Payment Ops",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            organizer: nil,
            participants: [],
            isOnlineMeeting: false,
            meetingURL: nil
        )

        store.setMeetingFamilyFolderPreference("Work/Payments/Merchant Standup", for: event)

        XCTAssertNil(store.meetingFamilyPreferences(for: event))
        XCTAssertTrue(store.meetingFamilyPreferencesByKey.isEmpty)
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

    func testSecretsLoadLazily() {
        let tracker = LoadTracker()
        let secretStore = AppSecretStore(
            loadValue: { key in
                tracker.loadedKeys.append(key)
                return key == "openRouterApiKey" ? "sk-existing" : nil
            },
            saveValue: { key, value in
                tracker.savedValues[key] = value
            }
        )

        let store = makeStore(secretStore: secretStore)

        XCTAssertTrue(tracker.loadedKeys.isEmpty)
        XCTAssertEqual(store.llmProvider, .openRouter)
        XCTAssertTrue(tracker.loadedKeys.isEmpty)

        XCTAssertEqual(store.openRouterApiKey, "sk-existing")
        XCTAssertEqual(tracker.loadedKeys, ["openRouterApiKey"])

        XCTAssertEqual(store.openRouterApiKey, "sk-existing")
        XCTAssertEqual(tracker.loadedKeys, ["openRouterApiKey"])

        store.openRouterApiKey = " sk-updated "
        XCTAssertEqual(store.openRouterApiKey, "sk-updated")
        XCTAssertEqual(tracker.loadedKeys, ["openRouterApiKey"])
        XCTAssertEqual(tracker.savedValues["openRouterApiKey"], "sk-updated")
    }

    // MARK: - Cloud ASR API Keys

    func testAssemblyAIApiKeyDefaultsToEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.assemblyAIApiKey, "")
    }

    func testElevenLabsApiKeyDefaultsToEmpty() {
        let store = makeStore()
        XCTAssertEqual(store.elevenLabsApiKey, "")
    }

    func testAssemblyAIApiKeyAutoTrimsWhitespace() {
        let store = makeStore()
        store.assemblyAIApiKey = "  sk-test-abc123  \n"
        XCTAssertEqual(store.assemblyAIApiKey, "sk-test-abc123")
    }

    func testElevenLabsApiKeyAutoTrimsWhitespace() {
        let store = makeStore()
        store.elevenLabsApiKey = "  xi-test-abc123  \n"
        XCTAssertEqual(store.elevenLabsApiKey, "xi-test-abc123")
    }

    func testCloudASRApiKeyRoutesCorrectly() {
        let store = makeStore()
        store.assemblyAIApiKey = "aai-key"
        store.elevenLabsApiKey = "el-key"

        store.transcriptionModel = .assemblyAI
        XCTAssertEqual(store.cloudASRApiKey, "aai-key")

        store.transcriptionModel = .elevenLabsScribe
        XCTAssertEqual(store.cloudASRApiKey, "el-key")

        store.transcriptionModel = .parakeetV2
        XCTAssertEqual(store.cloudASRApiKey, "")
    }
}
