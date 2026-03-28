import AppKit
import CoreAudio
import Foundation
import Observation
import Security

@Observable
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let secretStore: AppSecretStore

    // MARK: - AI Settings

    @ObservationIgnored nonisolated(unsafe) private var _llmProvider: LLMProvider
    var llmProvider: LLMProvider {
        get { access(keyPath: \.llmProvider); return _llmProvider }
        set {
            withMutation(keyPath: \.llmProvider) {
                _llmProvider = newValue
                defaults.set(newValue.rawValue, forKey: "llmProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openRouterApiKey: String
    var openRouterApiKey: String {
        get { access(keyPath: \.openRouterApiKey); return _openRouterApiKey }
        set {
            withMutation(keyPath: \.openRouterApiKey) {
                _openRouterApiKey = newValue
                secretStore.save(key: "openRouterApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaBaseURL: String
    var ollamaBaseURL: String {
        get { access(keyPath: \.ollamaBaseURL); return _ollamaBaseURL }
        set {
            withMutation(keyPath: \.ollamaBaseURL) {
                _ollamaBaseURL = newValue
                defaults.set(newValue, forKey: "ollamaBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaLLMModel: String
    var ollamaLLMModel: String {
        get { access(keyPath: \.ollamaLLMModel); return _ollamaLLMModel }
        set {
            withMutation(keyPath: \.ollamaLLMModel) {
                _ollamaLLMModel = newValue
                defaults.set(newValue, forKey: "ollamaLLMModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaEmbedModel: String
    var ollamaEmbedModel: String {
        get { access(keyPath: \.ollamaEmbedModel); return _ollamaEmbedModel }
        set {
            withMutation(keyPath: \.ollamaEmbedModel) {
                _ollamaEmbedModel = newValue
                defaults.set(newValue, forKey: "ollamaEmbedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxBaseURL: String
    var mlxBaseURL: String {
        get { access(keyPath: \.mlxBaseURL); return _mlxBaseURL }
        set {
            withMutation(keyPath: \.mlxBaseURL) {
                _mlxBaseURL = newValue
                defaults.set(newValue, forKey: "mlxBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxModel: String
    var mlxModel: String {
        get { access(keyPath: \.mlxModel); return _mlxModel }
        set {
            withMutation(keyPath: \.mlxModel) {
                _mlxModel = newValue
                defaults.set(newValue, forKey: "mlxModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMBaseURL: String
    var openAILLMBaseURL: String {
        get { access(keyPath: \.openAILLMBaseURL); return _openAILLMBaseURL }
        set {
            withMutation(keyPath: \.openAILLMBaseURL) {
                _openAILLMBaseURL = newValue
                defaults.set(newValue, forKey: "openAILLMBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMApiKey: String
    var openAILLMApiKey: String {
        get { access(keyPath: \.openAILLMApiKey); return _openAILLMApiKey }
        set {
            withMutation(keyPath: \.openAILLMApiKey) {
                _openAILLMApiKey = newValue
                secretStore.save(key: "openAILLMApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAILLMModel: String
    var openAILLMModel: String {
        get { access(keyPath: \.openAILLMModel); return _openAILLMModel }
        set {
            withMutation(keyPath: \.openAILLMModel) {
                _openAILLMModel = newValue
                defaults.set(newValue, forKey: "openAILLMModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedBaseURL: String
    var openAIEmbedBaseURL: String {
        get { access(keyPath: \.openAIEmbedBaseURL); return _openAIEmbedBaseURL }
        set {
            withMutation(keyPath: \.openAIEmbedBaseURL) {
                _openAIEmbedBaseURL = newValue
                defaults.set(newValue, forKey: "openAIEmbedBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedApiKey: String
    var openAIEmbedApiKey: String {
        get { access(keyPath: \.openAIEmbedApiKey); return _openAIEmbedApiKey }
        set {
            withMutation(keyPath: \.openAIEmbedApiKey) {
                _openAIEmbedApiKey = newValue
                secretStore.save(key: "openAIEmbedApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openAIEmbedModel: String
    var openAIEmbedModel: String {
        get { access(keyPath: \.openAIEmbedModel); return _openAIEmbedModel }
        set {
            withMutation(keyPath: \.openAIEmbedModel) {
                _openAIEmbedModel = newValue
                defaults.set(newValue, forKey: "openAIEmbedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _selectedModel: String
    var selectedModel: String {
        get { access(keyPath: \.selectedModel); return _selectedModel }
        set {
            withMutation(keyPath: \.selectedModel) {
                _selectedModel = newValue
                defaults.set(newValue, forKey: "selectedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _embeddingProvider: EmbeddingProvider
    var embeddingProvider: EmbeddingProvider {
        get { access(keyPath: \.embeddingProvider); return _embeddingProvider }
        set {
            withMutation(keyPath: \.embeddingProvider) {
                _embeddingProvider = newValue
                defaults.set(newValue.rawValue, forKey: "embeddingProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _voyageApiKey: String
    var voyageApiKey: String {
        get { access(keyPath: \.voyageApiKey); return _voyageApiKey }
        set {
            withMutation(keyPath: \.voyageApiKey) {
                _voyageApiKey = newValue
                secretStore.save(key: "voyageApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionVerbosity: SuggestionVerbosity
    var suggestionVerbosity: SuggestionVerbosity {
        get { access(keyPath: \.suggestionVerbosity); return _suggestionVerbosity }
        set {
            withMutation(keyPath: \.suggestionVerbosity) {
                _suggestionVerbosity = newValue
                defaults.set(newValue.rawValue, forKey: "suggestionVerbosity")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableTranscriptRefinement: Bool
    var enableTranscriptRefinement: Bool {
        get { access(keyPath: \.enableTranscriptRefinement); return _enableTranscriptRefinement }
        set {
            withMutation(keyPath: \.enableTranscriptRefinement) {
                _enableTranscriptRefinement = newValue
                defaults.set(newValue, forKey: "enableTranscriptRefinement")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _realtimeModel: String
    var realtimeModel: String {
        get { access(keyPath: \.realtimeModel); return _realtimeModel }
        set {
            withMutation(keyPath: \.realtimeModel) {
                _realtimeModel = newValue
                defaults.set(newValue, forKey: "realtimeModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _realtimeOllamaModel: String
    var realtimeOllamaModel: String {
        get { access(keyPath: \.realtimeOllamaModel); return _realtimeOllamaModel }
        set {
            withMutation(keyPath: \.realtimeOllamaModel) {
                _realtimeOllamaModel = newValue
                defaults.set(newValue, forKey: "realtimeOllamaModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionPanelEnabled: Bool
    var suggestionPanelEnabled: Bool {
        get { access(keyPath: \.suggestionPanelEnabled); return _suggestionPanelEnabled }
        set {
            withMutation(keyPath: \.suggestionPanelEnabled) {
                _suggestionPanelEnabled = newValue
                defaults.set(newValue, forKey: "suggestionPanelEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidebarMode: SidebarMode
    var sidebarMode: SidebarMode {
        get { access(keyPath: \.sidebarMode); return _sidebarMode }
        set {
            withMutation(keyPath: \.sidebarMode) {
                _sidebarMode = newValue
                defaults.set(newValue.rawValue, forKey: "sidebarMode")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastIntensity: SidecastIntensity
    var sidecastIntensity: SidecastIntensity {
        get { access(keyPath: \.sidecastIntensity); return _sidecastIntensity }
        set {
            withMutation(keyPath: \.sidecastIntensity) {
                _sidecastIntensity = newValue
                defaults.set(newValue.rawValue, forKey: "sidecastIntensity")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastPersonas: [SidecastPersona]
    var sidecastPersonas: [SidecastPersona] {
        get { access(keyPath: \.sidecastPersonas); return _sidecastPersonas }
        set {
            withMutation(keyPath: \.sidecastPersonas) {
                _sidecastPersonas = newValue
                defaults.set(Self.encodePersonas(newValue), forKey: "sidecastPersonas")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _preFetchIntervalSeconds: Double
    var preFetchIntervalSeconds: Double {
        get { access(keyPath: \.preFetchIntervalSeconds); return _preFetchIntervalSeconds }
        set {
            withMutation(keyPath: \.preFetchIntervalSeconds) {
                _preFetchIntervalSeconds = newValue
                defaults.set(newValue, forKey: "preFetchIntervalSeconds")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kbSimilarityThreshold: Double
    var kbSimilarityThreshold: Double {
        get { access(keyPath: \.kbSimilarityThreshold); return _kbSimilarityThreshold }
        set {
            withMutation(keyPath: \.kbSimilarityThreshold) {
                _kbSimilarityThreshold = newValue
                defaults.set(newValue, forKey: "kbSimilarityThreshold")
            }
        }
    }

    // MARK: - Capture Settings

    @ObservationIgnored nonisolated(unsafe) private var _inputDeviceID: AudioDeviceID
    var inputDeviceID: AudioDeviceID {
        get { access(keyPath: \.inputDeviceID); return _inputDeviceID }
        set {
            withMutation(keyPath: \.inputDeviceID) {
                _inputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "inputDeviceID")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionModel: TranscriptionModel
    var transcriptionModel: TranscriptionModel {
        get { access(keyPath: \.transcriptionModel); return _transcriptionModel }
        set {
            withMutation(keyPath: \.transcriptionModel) {
                _transcriptionModel = newValue
                defaults.set(newValue.rawValue, forKey: "transcriptionModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionLocale: String
    var transcriptionLocale: String {
        get { access(keyPath: \.transcriptionLocale); return _transcriptionLocale }
        set {
            withMutation(keyPath: \.transcriptionLocale) {
                _transcriptionLocale = newValue
                defaults.set(newValue, forKey: "transcriptionLocale")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionCustomVocabulary: String
    var transcriptionCustomVocabulary: String {
        get { access(keyPath: \.transcriptionCustomVocabulary); return _transcriptionCustomVocabulary }
        set {
            withMutation(keyPath: \.transcriptionCustomVocabulary) {
                _transcriptionCustomVocabulary = newValue
                defaults.set(newValue, forKey: "transcriptionCustomVocabulary")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _saveAudioRecording: Bool
    var saveAudioRecording: Bool {
        get { access(keyPath: \.saveAudioRecording); return _saveAudioRecording }
        set {
            withMutation(keyPath: \.saveAudioRecording) {
                _saveAudioRecording = newValue
                defaults.set(newValue, forKey: "saveAudioRecording")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableEchoCancellation: Bool
    var enableEchoCancellation: Bool {
        get { access(keyPath: \.enableEchoCancellation); return _enableEchoCancellation }
        set {
            withMutation(keyPath: \.enableEchoCancellation) {
                _enableEchoCancellation = newValue
                defaults.set(newValue, forKey: "enableEchoCancellation")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableBatchRefinement: Bool
    var enableBatchRefinement: Bool {
        get { access(keyPath: \.enableBatchRefinement); return _enableBatchRefinement }
        set {
            withMutation(keyPath: \.enableBatchRefinement) {
                _enableBatchRefinement = newValue
                defaults.set(newValue, forKey: "enableBatchRefinement")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchTranscriptionModel: TranscriptionModel
    var batchTranscriptionModel: TranscriptionModel {
        get { access(keyPath: \.batchTranscriptionModel); return _batchTranscriptionModel }
        set {
            withMutation(keyPath: \.batchTranscriptionModel) {
                _batchTranscriptionModel = newValue
                defaults.set(newValue.rawValue, forKey: "batchTranscriptionModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _enableDiarization: Bool
    var enableDiarization: Bool {
        get { access(keyPath: \.enableDiarization); return _enableDiarization }
        set {
            withMutation(keyPath: \.enableDiarization) {
                _enableDiarization = newValue
                defaults.set(newValue, forKey: "enableDiarization")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _diarizationVariant: String
    var diarizationVariant: DiarizationVariant {
        get { access(keyPath: \.diarizationVariant); return DiarizationVariant(rawValue: _diarizationVariant) ?? .dihard3 }
        set {
            withMutation(keyPath: \.diarizationVariant) {
                _diarizationVariant = newValue.rawValue
                defaults.set(newValue.rawValue, forKey: "diarizationVariant")
            }
        }
    }

    // MARK: - Detection Settings

    @ObservationIgnored nonisolated(unsafe) private var _meetingAutoDetectEnabled: Bool
    var meetingAutoDetectEnabled: Bool {
        get { access(keyPath: \.meetingAutoDetectEnabled); return _meetingAutoDetectEnabled }
        set {
            withMutation(keyPath: \.meetingAutoDetectEnabled) {
                _meetingAutoDetectEnabled = newValue
                defaults.set(newValue, forKey: "meetingAutoDetectEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _customMeetingAppBundleIDs: [String]
    var customMeetingAppBundleIDs: [String] {
        get { access(keyPath: \.customMeetingAppBundleIDs); return _customMeetingAppBundleIDs }
        set {
            withMutation(keyPath: \.customMeetingAppBundleIDs) {
                _customMeetingAppBundleIDs = newValue
                defaults.set(newValue, forKey: "customMeetingAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ignoredAppBundleIDs: [String]
    var ignoredAppBundleIDs: [String] {
        get { access(keyPath: \.ignoredAppBundleIDs); return _ignoredAppBundleIDs }
        set {
            withMutation(keyPath: \.ignoredAppBundleIDs) {
                _ignoredAppBundleIDs = newValue
                defaults.set(newValue, forKey: "ignoredAppBundleIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _silenceTimeoutMinutes: Int
    var silenceTimeoutMinutes: Int {
        get { access(keyPath: \.silenceTimeoutMinutes); return _silenceTimeoutMinutes }
        set {
            withMutation(keyPath: \.silenceTimeoutMinutes) {
                _silenceTimeoutMinutes = newValue
                defaults.set(newValue, forKey: "silenceTimeoutMinutes")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _detectionLogEnabled: Bool
    var detectionLogEnabled: Bool {
        get { access(keyPath: \.detectionLogEnabled); return _detectionLogEnabled }
        set {
            withMutation(keyPath: \.detectionLogEnabled) {
                _detectionLogEnabled = newValue
                defaults.set(newValue, forKey: "detectionLogEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasShownAutoDetectExplanation: Bool
    var hasShownAutoDetectExplanation: Bool {
        get { access(keyPath: \.hasShownAutoDetectExplanation); return _hasShownAutoDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownAutoDetectExplanation) {
                _hasShownAutoDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownAutoDetectExplanation")
            }
        }
    }

    // MARK: - Privacy Settings

    @ObservationIgnored nonisolated(unsafe) private var _hasAcknowledgedRecordingConsent: Bool
    var hasAcknowledgedRecordingConsent: Bool {
        get { access(keyPath: \.hasAcknowledgedRecordingConsent); return _hasAcknowledgedRecordingConsent }
        set {
            withMutation(keyPath: \.hasAcknowledgedRecordingConsent) {
                _hasAcknowledgedRecordingConsent = newValue
                defaults.set(newValue, forKey: "hasAcknowledgedRecordingConsent")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hideFromScreenShare: Bool
    var hideFromScreenShare: Bool {
        get { access(keyPath: \.hideFromScreenShare); return _hideFromScreenShare }
        set {
            withMutation(keyPath: \.hideFromScreenShare) {
                _hideFromScreenShare = newValue
                defaults.set(newValue, forKey: "hideFromScreenShare")
                applyScreenShareVisibility()
            }
        }
    }

    // MARK: - Import Settings

    @ObservationIgnored nonisolated(unsafe) private var _granolaApiKey: String
    var granolaApiKey: String {
        get { access(keyPath: \.granolaApiKey); return _granolaApiKey }
        set {
            withMutation(keyPath: \.granolaApiKey) {
                _granolaApiKey = newValue
                secretStore.save(key: "granolaApiKey", value: newValue)
            }
        }
    }

    // MARK: - Webhook Settings

    @ObservationIgnored nonisolated(unsafe) private var _webhookEnabled: Bool
    var webhookEnabled: Bool {
        get { access(keyPath: \.webhookEnabled); return _webhookEnabled }
        set {
            withMutation(keyPath: \.webhookEnabled) {
                _webhookEnabled = newValue
                defaults.set(newValue, forKey: "webhookEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _webhookURL: String
    var webhookURL: String {
        get { access(keyPath: \.webhookURL); return _webhookURL }
        set {
            withMutation(keyPath: \.webhookURL) {
                _webhookURL = newValue
                defaults.set(newValue, forKey: "webhookURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _webhookSecret: String
    var webhookSecret: String {
        get { access(keyPath: \.webhookSecret); return _webhookSecret }
        set {
            withMutation(keyPath: \.webhookSecret) {
                _webhookSecret = newValue
                secretStore.save(key: "webhookSecret", value: newValue)
            }
        }
    }

    // MARK: - UI Settings

    @ObservationIgnored nonisolated(unsafe) private var _showLiveTranscript: Bool
    var showLiveTranscript: Bool {
        get { access(keyPath: \.showLiveTranscript); return _showLiveTranscript }
        set {
            withMutation(keyPath: \.showLiveTranscript) {
                _showLiveTranscript = newValue
                defaults.set(newValue, forKey: "showLiveTranscript")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _notesFolderPath: String
    var notesFolderPath: String {
        get { access(keyPath: \.notesFolderPath); return _notesFolderPath }
        set {
            withMutation(keyPath: \.notesFolderPath) {
                _notesFolderPath = newValue
                defaults.set(newValue, forKey: "notesFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kbFolderPath: String
    var kbFolderPath: String {
        get { access(keyPath: \.kbFolderPath); return _kbFolderPath }
        set {
            withMutation(keyPath: \.kbFolderPath) {
                _kbFolderPath = newValue
                defaults.set(newValue, forKey: "kbFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _hasSeenLaunchAtLoginSuggestion: Bool
    var hasSeenLaunchAtLoginSuggestion: Bool {
        get { access(keyPath: \.hasSeenLaunchAtLoginSuggestion); return _hasSeenLaunchAtLoginSuggestion }
        set {
            withMutation(keyPath: \.hasSeenLaunchAtLoginSuggestion) {
                _hasSeenLaunchAtLoginSuggestion = newValue
                defaults.set(newValue, forKey: "hasSeenLaunchAtLoginSuggestion")
            }
        }
    }

    // MARK: - Initialization

    init(storage: SettingsStorage = .live()) {
        self.defaults = storage.defaults
        self.secretStore = storage.secretStore

        let defaults = storage.defaults

        // One-time migrations from previous bundle IDs
        if storage.runMigrations {
            Self.migrateFromOldBundleIfNeeded(defaults: defaults)
            Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)
            Self.migrateKeychainServiceIfNeeded(defaults: defaults)
        }

        // AI Settings
        self._llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self._openRouterApiKey = storage.secretStore.load(key: "openRouterApiKey") ?? ""
        self._ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self._ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self._ollamaEmbedModel = defaults.string(forKey: "ollamaEmbedModel") ?? "nomic-embed-text"
        self._mlxBaseURL = defaults.string(forKey: "mlxBaseURL") ?? "http://localhost:8080"
        self._mlxModel = defaults.string(forKey: "mlxModel") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        self._openAILLMBaseURL = defaults.string(forKey: "openAILLMBaseURL") ?? "http://localhost:4000"
        self._openAILLMApiKey = storage.secretStore.load(key: "openAILLMApiKey") ?? ""
        self._openAILLMModel = defaults.string(forKey: "openAILLMModel") ?? ""
        self._openAIEmbedBaseURL = defaults.string(forKey: "openAIEmbedBaseURL") ?? "http://localhost:8080"
        self._openAIEmbedApiKey = storage.secretStore.load(key: "openAIEmbedApiKey") ?? ""
        self._openAIEmbedModel = defaults.string(forKey: "openAIEmbedModel") ?? "text-embedding-3-small"
        self._selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self._embeddingProvider = EmbeddingProvider(rawValue: defaults.string(forKey: "embeddingProvider") ?? "") ?? .voyageAI
        self._voyageApiKey = storage.secretStore.load(key: "voyageApiKey") ?? ""
        self._suggestionVerbosity = SuggestionVerbosity(
            rawValue: defaults.string(forKey: "suggestionVerbosity") ?? ""
        ) ?? .quiet
        self._enableTranscriptRefinement = defaults.bool(forKey: "enableTranscriptRefinement")
        self._realtimeModel = defaults.string(forKey: "realtimeModel") ?? "google/gemini-3.1-flash-lite-preview"
        self._realtimeOllamaModel = defaults.string(forKey: "realtimeOllamaModel") ?? ""
        if defaults.object(forKey: "suggestionPanelEnabled") == nil {
            self._suggestionPanelEnabled = true
        } else {
            self._suggestionPanelEnabled = defaults.bool(forKey: "suggestionPanelEnabled")
        }
        self._sidebarMode = SidebarMode(rawValue: defaults.string(forKey: "sidebarMode") ?? "") ?? .sidecast
        self._sidecastIntensity = SidecastIntensity(rawValue: defaults.string(forKey: "sidecastIntensity") ?? "") ?? .balanced
        self._sidecastPersonas = Self.decodePersonas(defaults.data(forKey: "sidecastPersonas")) ?? SidecastPersona.starterPack
        self._preFetchIntervalSeconds = defaults.object(forKey: "preFetchIntervalSeconds") != nil
            ? defaults.double(forKey: "preFetchIntervalSeconds") : 4.0
        self._kbSimilarityThreshold = defaults.object(forKey: "kbSimilarityThreshold") != nil
            ? defaults.double(forKey: "kbSimilarityThreshold") : 0.35

        // Capture Settings
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .parakeetV2
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self._transcriptionCustomVocabulary = defaults.string(forKey: "transcriptionCustomVocabulary") ?? ""
        self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")

        if defaults.object(forKey: "enableEchoCancellation") == nil {
            self._enableEchoCancellation = true
        } else {
            self._enableEchoCancellation = defaults.bool(forKey: "enableEchoCancellation")
        }

        if defaults.object(forKey: "enableBatchRefinement") == nil {
            self._enableBatchRefinement = false
        } else {
            self._enableBatchRefinement = defaults.bool(forKey: "enableBatchRefinement")
        }
        self._batchTranscriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "batchTranscriptionModel") ?? ""
        ) ?? .whisperLargeV3Turbo
        self._enableDiarization = defaults.bool(forKey: "enableDiarization")
        self._diarizationVariant = defaults.string(forKey: "diarizationVariant") ?? DiarizationVariant.dihard3.rawValue

        // Detection Settings
        if defaults.object(forKey: "meetingAutoDetectEnabled") == nil {
            self._meetingAutoDetectEnabled = true
        } else {
            self._meetingAutoDetectEnabled = defaults.bool(forKey: "meetingAutoDetectEnabled")
        }
        self._customMeetingAppBundleIDs = defaults.stringArray(forKey: "customMeetingAppBundleIDs") ?? []
        self._ignoredAppBundleIDs = defaults.stringArray(forKey: "ignoredAppBundleIDs") ?? []
        self._silenceTimeoutMinutes = defaults.object(forKey: "silenceTimeoutMinutes") != nil
            ? defaults.integer(forKey: "silenceTimeoutMinutes") : 15
        self._detectionLogEnabled = defaults.bool(forKey: "detectionLogEnabled")
        self._hasShownAutoDetectExplanation = defaults.bool(forKey: "hasShownAutoDetectExplanation")

        // Privacy Settings
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = true
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Import Settings
        self._granolaApiKey = storage.secretStore.load(key: "granolaApiKey") ?? ""

        // Webhook Settings
        self._webhookEnabled = defaults.bool(forKey: "webhookEnabled")
        self._webhookURL = defaults.string(forKey: "webhookURL") ?? ""
        self._webhookSecret = storage.secretStore.load(key: "webhookSecret") ?? ""

        // UI Settings
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }
        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self._hasSeenLaunchAtLoginSuggestion = defaults.bool(forKey: "hasSeenLaunchAtLoginSuggestion")

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

        // Prevent Spotlight from indexing transcript contents
        Self.dropMetadataNeverIndex(atPath: notesFolderPath)
    }

    // MARK: - Computed Properties

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

    var transcriptionModelDisplay: String {
        transcriptionModel.displayName
    }

    /// The model name to display in the UI, respecting the active LLM provider.
    var activeModelDisplay: String {
        let raw: String
        switch llmProvider {
        case .openRouter: raw = selectedModel
        case .ollama: raw = ollamaLLMModel
        case .mlx: raw = mlxModel
        case .openAICompatible: raw = openAILLMModel
        }
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    /// The model ID to use for real-time suggestion synthesis.
    var activeRealtimeModel: String {
        switch llmProvider {
        case .openRouter: return realtimeModel
        case .ollama: return realtimeOllamaModel.isEmpty ? ollamaLLMModel : realtimeOllamaModel
        case .mlx: return mlxModel
        case .openAICompatible: return openAILLMModel
        }
    }

    /// Display name for the active realtime model.
    var activeRealtimeModelDisplay: String {
        let raw = activeRealtimeModel
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

    var enabledSidecastPersonas: [SidecastPersona] {
        sidecastPersonas.filter(\.isEnabled)
    }

    func toggleSidecastPersona(at index: Int) {
        guard sidecastPersonas.indices.contains(index) else { return }
        sidecastPersonas[index].isEnabled.toggle()
    }

    // MARK: - Screen Share Visibility

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    // MARK: - Spotlight Indexing

    /// Place a .metadata_never_index sentinel so Spotlight skips the directory.
    private static func dropMetadataNeverIndex(atPath directoryPath: String) {
        let sentinel = URL(fileURLWithPath: directoryPath).appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    private static func encodePersonas(_ personas: [SidecastPersona]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(personas)
    }

    private static func decodePersonas(_ data: Data?) -> [SidecastPersona]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([SidecastPersona].self, from: data)
    }
}

// MARK: - Migration

extension SettingsStore {
    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults and Keychain entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let oldService = "com.onthespot.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }
    }

    /// Migrate settings from the previous "OpenGranola" (com.opengranola.app) bundle.
    private static func migrateFromOpenGranolaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenGranola"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent",
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }

        migrateFilesFromOpenGranola(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, KB cache, transcripts)
    /// from ~/Library/Application Support/OpenGranola/ to OpenOats/ and
    /// handle the implicit KB folder default.
    private static func migrateFilesFromOpenGranola(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenGranola")
        let newAppSupportDir = appSupport.appendingPathComponent("OpenOats")

        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }

            let oldCache = oldAppSupportDir.appendingPathComponent("kb_cache.json")
            let newCache = newAppSupportDir.appendingPathComponent("kb_cache.json")
            if fm.fileExists(atPath: oldCache.path) && !fm.fileExists(atPath: newCache.path) {
                try? fm.moveItem(at: oldCache, to: newCache)
            }
        }

        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir = home.appendingPathComponent("Documents/OpenOats")

        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        let activeKB = defaults.string(forKey: "kbFolderPath") ?? ""
        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeKB && oldDocDir.path != activeNotes {
            try? fm.createDirectory(at: newDocDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: oldDocDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "txt" {
                    let dest = newDocDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
        }
    }

    /// Migrate keychain entries from the old "com.opengranola.app" service to the
    /// current "com.openoats.app" service.
    private static func migrateKeychainServiceIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateKeychainToOpenOats"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey", "openAIEmbedApiKey", "openAILLMApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }
    }

    /// Read a keychain entry from a specific service (used for migration only).
    private static func loadKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Backward-compatible alias so existing code continues to compile during migration.
typealias AppSettings = SettingsStore
