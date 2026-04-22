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
    private static let enableLiveTranscriptCleanupLegacyKey = "enableTranscriptRefinement"
    private static let enableBatchRetranscriptionLegacyKey = "enableBatchRefinement"
    @ObservationIgnored private var loadedSecretKeys: Set<String> = []

    private func loadSecretIfNeeded(
        key: String,
        currentValue: String,
        assign: (String) -> Void
    ) -> String {
        guard !loadedSecretKeys.contains(key) else { return currentValue }
        let value = secretStore.load(key: key) ?? ""
        loadedSecretKeys.insert(key)
        assign(value)
        return value
    }

    private func markSecretLoaded(_ key: String) {
        loadedSecretKeys.insert(key)
    }

    func isSecretLoaded(_ key: String) -> Bool {
        loadedSecretKeys.contains(key)
    }

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
        get {
            access(keyPath: \.openRouterApiKey)
            return loadSecretIfNeeded(key: "openRouterApiKey", currentValue: _openRouterApiKey) {
                _openRouterApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openRouterApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openRouterApiKey = trimmed
                markSecretLoaded("openRouterApiKey")
                secretStore.save(key: "openRouterApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assemblyAIApiKey: String
    var assemblyAIApiKey: String {
        get {
            access(keyPath: \.assemblyAIApiKey)
            return loadSecretIfNeeded(key: "assemblyAIApiKey", currentValue: _assemblyAIApiKey) {
                _assemblyAIApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.assemblyAIApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _assemblyAIApiKey = trimmed
                markSecretLoaded("assemblyAIApiKey")
                secretStore.save(key: "assemblyAIApiKey", value: trimmed)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _elevenLabsApiKey: String
    var elevenLabsApiKey: String {
        get {
            access(keyPath: \.elevenLabsApiKey)
            return loadSecretIfNeeded(key: "elevenLabsApiKey", currentValue: _elevenLabsApiKey) {
                _elevenLabsApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.elevenLabsApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _elevenLabsApiKey = trimmed
                markSecretLoaded("elevenLabsApiKey")
                secretStore.save(key: "elevenLabsApiKey", value: trimmed)
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
        get {
            access(keyPath: \.openAILLMApiKey)
            return loadSecretIfNeeded(key: "openAILLMApiKey", currentValue: _openAILLMApiKey) {
                _openAILLMApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openAILLMApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openAILLMApiKey = trimmed
                markSecretLoaded("openAILLMApiKey")
                secretStore.save(key: "openAILLMApiKey", value: trimmed)
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
        get {
            access(keyPath: \.openAIEmbedApiKey)
            return loadSecretIfNeeded(key: "openAIEmbedApiKey", currentValue: _openAIEmbedApiKey) {
                _openAIEmbedApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.openAIEmbedApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _openAIEmbedApiKey = trimmed
                markSecretLoaded("openAIEmbedApiKey")
                secretStore.save(key: "openAIEmbedApiKey", value: trimmed)
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
        get {
            access(keyPath: \.voyageApiKey)
            return loadSecretIfNeeded(key: "voyageApiKey", currentValue: _voyageApiKey) {
                _voyageApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.voyageApiKey) {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                _voyageApiKey = trimmed
                markSecretLoaded("voyageApiKey")
                secretStore.save(key: "voyageApiKey", value: trimmed)
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

    @ObservationIgnored nonisolated(unsafe) private var _enableLiveTranscriptCleanup: Bool
    var enableLiveTranscriptCleanup: Bool {
        get { access(keyPath: \.enableLiveTranscriptCleanup); return _enableLiveTranscriptCleanup }
        set {
            withMutation(keyPath: \.enableLiveTranscriptCleanup) {
                _enableLiveTranscriptCleanup = newValue
                defaults.set(newValue, forKey: "enableLiveTranscriptCleanup")
                defaults.set(newValue, forKey: Self.enableLiveTranscriptCleanupLegacyKey)
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

    @ObservationIgnored nonisolated(unsafe) private var _suggestionsAlwaysOnTop: Bool
    var suggestionsAlwaysOnTop: Bool {
        get { access(keyPath: \.suggestionsAlwaysOnTop); return _suggestionsAlwaysOnTop }
        set {
            withMutation(keyPath: \.suggestionsAlwaysOnTop) {
                _suggestionsAlwaysOnTop = newValue
                defaults.set(newValue, forKey: "suggestionsAlwaysOnTop")
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

    @ObservationIgnored nonisolated(unsafe) private var _sidecastTemperature: Double
    var sidecastTemperature: Double {
        get { access(keyPath: \.sidecastTemperature); return _sidecastTemperature }
        set {
            withMutation(keyPath: \.sidecastTemperature) {
                _sidecastTemperature = newValue
                defaults.set(newValue, forKey: "sidecastTemperature")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastMaxTokens: Int
    var sidecastMaxTokens: Int {
        get { access(keyPath: \.sidecastMaxTokens); return _sidecastMaxTokens }
        set {
            withMutation(keyPath: \.sidecastMaxTokens) {
                _sidecastMaxTokens = newValue
                defaults.set(newValue, forKey: "sidecastMaxTokens")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastSystemPrompt: String
    var sidecastSystemPrompt: String {
        get { access(keyPath: \.sidecastSystemPrompt); return _sidecastSystemPrompt }
        set {
            withMutation(keyPath: \.sidecastSystemPrompt) {
                _sidecastSystemPrompt = newValue
                defaults.set(newValue, forKey: "sidecastSystemPrompt")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _sidecastMinValueThreshold: Double
    var sidecastMinValueThreshold: Double {
        get { access(keyPath: \.sidecastMinValueThreshold); return _sidecastMinValueThreshold }
        set {
            withMutation(keyPath: \.sidecastMinValueThreshold) {
                _sidecastMinValueThreshold = newValue
                defaults.set(newValue, forKey: "sidecastMinValueThreshold")
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
                if newValue > 0 {
                    if let uid = MicCapture.deviceUID(for: newValue) {
                        defaults.set(uid, forKey: "inputDeviceUID")
                    }
                    let name = MicCapture.availableInputDevices().first(where: { $0.id == newValue })?.name
                    if let name { defaults.set(name, forKey: "inputDeviceName") }
                } else {
                    defaults.removeObject(forKey: "inputDeviceUID")
                    defaults.removeObject(forKey: "inputDeviceName")
                }
            }
        }
    }

    /// Stable UID of the last selected input device (survives reboots/reconnects).
    var inputDeviceUID: String? { defaults.string(forKey: "inputDeviceUID") }
    /// Cached display name for the last selected input device.
    var inputDeviceName: String? { defaults.string(forKey: "inputDeviceName") }

    @ObservationIgnored nonisolated(unsafe) private var _outputDeviceID: AudioDeviceID
    var outputDeviceID: AudioDeviceID {
        get { access(keyPath: \.outputDeviceID); return _outputDeviceID }
        set {
            withMutation(keyPath: \.outputDeviceID) {
                _outputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "outputDeviceID")
                if newValue > 0 {
                    if let uid = try? SystemAudioCapture.outputDeviceUID(for: newValue) {
                        defaults.set(uid, forKey: "outputDeviceUID")
                    }
                    let name = SystemAudioCapture.availableOutputDevices().first(where: { $0.id == newValue })?.name
                    if let name { defaults.set(name, forKey: "outputDeviceName") }
                } else {
                    defaults.removeObject(forKey: "outputDeviceUID")
                    defaults.removeObject(forKey: "outputDeviceName")
                }
            }
        }
    }

    /// Stable UID of the last selected output device (survives reboots/reconnects).
    var outputDeviceUID: String? { defaults.string(forKey: "outputDeviceUID") }
    /// Cached display name for the last selected output device.
    var outputDeviceName: String? { defaults.string(forKey: "outputDeviceName") }

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

    @ObservationIgnored nonisolated(unsafe) private var _removeFillerWords: Bool
    var removeFillerWords: Bool {
        get { access(keyPath: \.removeFillerWords); return _removeFillerWords }
        set {
            withMutation(keyPath: \.removeFillerWords) {
                _removeFillerWords = newValue
                defaults.set(newValue, forKey: "removeFillerWords")
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

    @ObservationIgnored nonisolated(unsafe) private var _enableBatchRetranscription: Bool
    var enableBatchRetranscription: Bool {
        get { access(keyPath: \.enableBatchRetranscription); return _enableBatchRetranscription }
        set {
            withMutation(keyPath: \.enableBatchRetranscription) {
                _enableBatchRetranscription = newValue
                defaults.set(newValue, forKey: "enableBatchRetranscription")
                defaults.set(newValue, forKey: Self.enableBatchRetranscriptionLegacyKey)
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

    @ObservationIgnored nonisolated(unsafe) private var _hasShownCameraDetectExplanation: Bool
    var hasShownCameraDetectExplanation: Bool {
        get { access(keyPath: \.hasShownCameraDetectExplanation); return _hasShownCameraDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownCameraDetectExplanation) {
                _hasShownCameraDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownCameraDetectExplanation")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _calendarIntegrationEnabled: Bool
    var calendarIntegrationEnabled: Bool {
        get { access(keyPath: \.calendarIntegrationEnabled); return _calendarIntegrationEnabled }
        set {
            withMutation(keyPath: \.calendarIntegrationEnabled) {
                _calendarIntegrationEnabled = newValue
                defaults.set(newValue, forKey: "calendarIntegrationEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _shareCalendarContextWithCloudNotes: Bool
    var shareCalendarContextWithCloudNotes: Bool {
        get { access(keyPath: \.shareCalendarContextWithCloudNotes); return _shareCalendarContextWithCloudNotes }
        set {
            withMutation(keyPath: \.shareCalendarContextWithCloudNotes) {
                _shareCalendarContextWithCloudNotes = newValue
                defaults.set(newValue, forKey: "shareCalendarContextWithCloudNotes")
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
        get {
            access(keyPath: \.granolaApiKey)
            return loadSecretIfNeeded(key: "granolaApiKey", currentValue: _granolaApiKey) {
                _granolaApiKey = $0
            }
        }
        set {
            withMutation(keyPath: \.granolaApiKey) {
                _granolaApiKey = newValue
                markSecretLoaded("granolaApiKey")
                secretStore.save(key: "granolaApiKey", value: newValue)
            }
        }
    }

    // MARK: - Apple Notes Settings

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesEnabled: Bool
    var appleNotesEnabled: Bool {
        get { access(keyPath: \.appleNotesEnabled); return _appleNotesEnabled }
        set {
            withMutation(keyPath: \.appleNotesEnabled) {
                _appleNotesEnabled = newValue
                defaults.set(newValue, forKey: "appleNotesEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesIncludeTranscript: Bool
    var appleNotesIncludeTranscript: Bool {
        get { access(keyPath: \.appleNotesIncludeTranscript); return _appleNotesIncludeTranscript }
        set {
            withMutation(keyPath: \.appleNotesIncludeTranscript) {
                _appleNotesIncludeTranscript = newValue
                defaults.set(newValue, forKey: "appleNotesIncludeTranscript")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesFolderName: String
    var appleNotesFolderName: String {
        get { access(keyPath: \.appleNotesFolderName); return _appleNotesFolderName }
        set {
            withMutation(keyPath: \.appleNotesFolderName) {
                _appleNotesFolderName = newValue
                defaults.set(newValue, forKey: "appleNotesFolderName")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesAccountName: String
    var appleNotesAccountName: String {
        get { access(keyPath: \.appleNotesAccountName); return _appleNotesAccountName }
        set {
            withMutation(keyPath: \.appleNotesAccountName) {
                _appleNotesAccountName = newValue
                defaults.set(newValue, forKey: "appleNotesAccountName")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _appleNotesAutoExport: Bool
    var appleNotesAutoExport: Bool {
        get { access(keyPath: \.appleNotesAutoExport); return _appleNotesAutoExport }
        set {
            withMutation(keyPath: \.appleNotesAutoExport) {
                _appleNotesAutoExport = newValue
                defaults.set(newValue, forKey: "appleNotesAutoExport")
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
        get {
            access(keyPath: \.webhookSecret)
            return loadSecretIfNeeded(key: "webhookSecret", currentValue: _webhookSecret) {
                _webhookSecret = $0
            }
        }
        set {
            withMutation(keyPath: \.webhookSecret) {
                _webhookSecret = newValue
                markSecretLoaded("webhookSecret")
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

    @ObservationIgnored nonisolated(unsafe) private var _notesFolders: [NotesFolderDefinition]
    var notesFolders: [NotesFolderDefinition] {
        get { access(keyPath: \.notesFolders); return _notesFolders }
        set {
            withMutation(keyPath: \.notesFolders) {
                _notesFolders = Self.normalizeNotesFolders(newValue)
                defaults.set(Self.encodeNotesFolders(_notesFolders), forKey: "notesFolders")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingPrepNotesByKey: [String: String]
    var meetingPrepNotesByKey: [String: String] {
        get { access(keyPath: \.meetingPrepNotesByKey); return _meetingPrepNotesByKey }
        set {
            withMutation(keyPath: \.meetingPrepNotesByKey) {
                _meetingPrepNotesByKey = Self.normalizeMeetingPrepNotes(newValue)
                defaults.set(Self.encodeMeetingPrepNotes(_meetingPrepNotesByKey), forKey: "meetingPrepNotesByKey")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingHistoryAliasesByKey: [String: String]
    var meetingHistoryAliasesByKey: [String: String] {
        get { access(keyPath: \.meetingHistoryAliasesByKey); return _meetingHistoryAliasesByKey }
        set {
            withMutation(keyPath: \.meetingHistoryAliasesByKey) {
                _meetingHistoryAliasesByKey = Self.normalizeMeetingHistoryAliases(newValue)
                defaults.set(
                    Self.encodeMeetingHistoryAliases(_meetingHistoryAliasesByKey),
                    forKey: "meetingHistoryAliasesByKey"
                )
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingFamilyPreferencesByKey: [String: MeetingFamilyPreferences]
    var meetingFamilyPreferencesByKey: [String: MeetingFamilyPreferences] {
        get { access(keyPath: \.meetingFamilyPreferencesByKey); return _meetingFamilyPreferencesByKey }
        set {
            withMutation(keyPath: \.meetingFamilyPreferencesByKey) {
                _meetingFamilyPreferencesByKey = Self.normalizeMeetingFamilyPreferences(newValue)
                defaults.set(
                    Self.encodeMeetingFamilyPreferences(_meetingFamilyPreferencesByKey),
                    forKey: "meetingFamilyPreferencesByKey"
                )
            }
        }
    }

    func meetingPrepNotes(for event: CalendarEvent) -> String {
        let key = canonicalMeetingHistoryKey(for: event)
        return meetingPrepNotesByKey[key] ?? ""
    }

    func setMeetingPrepNotes(_ text: String, for event: CalendarEvent) {
        let key = canonicalMeetingHistoryKey(for: event)
        var notes = meetingPrepNotesByKey
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.removeValue(forKey: key)
        } else {
            notes[key] = text
        }
        meetingPrepNotesByKey = notes
    }

    func canonicalMeetingHistoryKey(for event: CalendarEvent) -> String {
        canonicalMeetingHistoryKey(forHistoryKey: MeetingHistoryResolver.historyKey(for: event))
    }

    func canonicalMeetingHistoryKey(forHistoryKey historyKey: String) -> String {
        MeetingHistoryResolver.canonicalHistoryKey(
            for: historyKey,
            aliases: meetingHistoryAliasesByKey
        )
    }

    func meetingFamilyPreferences(for event: CalendarEvent) -> MeetingFamilyPreferences? {
        meetingFamilyPreferences(forHistoryKey: MeetingHistoryResolver.historyKey(for: event))
    }

    func meetingFamilyPreferences(forHistoryKey historyKey: String) -> MeetingFamilyPreferences? {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        return meetingFamilyPreferencesByKey[key]
    }

    func setMeetingFamilyTemplatePreference(_ templateID: UUID?, for event: CalendarEvent) {
        setMeetingFamilyTemplatePreference(
            templateID,
            forHistoryKey: MeetingHistoryResolver.historyKey(for: event)
        )
    }

    func setMeetingFamilyTemplatePreference(_ templateID: UUID?, forHistoryKey historyKey: String) {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        guard !key.isEmpty else { return }

        var preferences = meetingFamilyPreferencesByKey
        var value = preferences[key] ?? MeetingFamilyPreferences()
        value.templateID = templateID

        if value.isEmpty {
            preferences.removeValue(forKey: key)
        } else {
            preferences[key] = value
        }
        meetingFamilyPreferencesByKey = preferences
    }

    func setMeetingFamilyFolderPreference(_ folderPath: String?, for event: CalendarEvent) {
        setMeetingFamilyFolderPreference(
            folderPath,
            forHistoryKey: MeetingHistoryResolver.historyKey(for: event)
        )
    }

    func setMeetingFamilyFolderPreference(_ folderPath: String?, forHistoryKey historyKey: String) {
        let key = canonicalMeetingHistoryKey(forHistoryKey: historyKey)
        guard !key.isEmpty else { return }

        var preferences = meetingFamilyPreferencesByKey
        var value = preferences[key] ?? MeetingFamilyPreferences()
        value.folderPath = Self.normalizeMeetingFamilyFolderPath(folderPath)

        if value.isEmpty {
            preferences.removeValue(forKey: key)
        } else {
            preferences[key] = value
        }
        meetingFamilyPreferencesByKey = preferences
    }

    func linkMeetingHistoryAlias(from aliasHistoryKey: String, to canonicalHistoryKey: String) {
        let aliasKey = MeetingHistoryResolver.historyKey(for: aliasHistoryKey)
        let targetKey = canonicalMeetingHistoryKey(forHistoryKey: canonicalHistoryKey)
        guard !aliasKey.isEmpty, !targetKey.isEmpty, aliasKey != targetKey else { return }

        var aliases = meetingHistoryAliasesByKey
        aliases[aliasKey] = targetKey
        meetingHistoryAliasesByKey = aliases
    }

    /// Save a security-scoped bookmark for the user-selected notes folder.
    func saveNotesFolderBookmark(from url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: "notesFolderBookmark")
        } catch {
            Log.sessionRepository.error("Failed to create notes folder bookmark: \(error, privacy: .public)")
        }
    }

    /// Resolve the stored security-scoped bookmark to a URL.
    /// Returns `nil` if no bookmark is stored or resolution fails.
    func resolveNotesFolderBookmark() -> URL? {
        guard let data = defaults.data(forKey: "notesFolderBookmark") else {
            return nil
        }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveNotesFolderBookmark(from: url)
            }
            return url
        } catch {
            Log.sessionRepository.error("Failed to resolve notes folder bookmark: \(error, privacy: .public)")
            return nil
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

        // Migrate renamed settings keys (old -> new)
        if defaults.object(forKey: "enableLiveTranscriptCleanup") == nil,
           let oldValue = defaults.object(forKey: Self.enableLiveTranscriptCleanupLegacyKey) {
            defaults.set(oldValue, forKey: "enableLiveTranscriptCleanup")
        }
        if defaults.object(forKey: "enableBatchRetranscription") == nil,
           let oldValue = defaults.object(forKey: Self.enableBatchRetranscriptionLegacyKey) {
            defaults.set(oldValue, forKey: "enableBatchRetranscription")
        }

        // AI Settings
        self._llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self._openRouterApiKey = ""
        self._assemblyAIApiKey = ""
        self._elevenLabsApiKey = ""
        self._ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self._ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self._ollamaEmbedModel = defaults.string(forKey: "ollamaEmbedModel") ?? "nomic-embed-text"
        self._mlxBaseURL = defaults.string(forKey: "mlxBaseURL") ?? "http://localhost:8080"
        self._mlxModel = defaults.string(forKey: "mlxModel") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        self._openAILLMBaseURL = defaults.string(forKey: "openAILLMBaseURL") ?? "http://localhost:4000"
        self._openAILLMApiKey = ""
        self._openAILLMModel = defaults.string(forKey: "openAILLMModel") ?? ""
        self._openAIEmbedBaseURL = defaults.string(forKey: "openAIEmbedBaseURL") ?? "http://localhost:8080"
        self._openAIEmbedApiKey = ""
        self._openAIEmbedModel = defaults.string(forKey: "openAIEmbedModel") ?? "text-embedding-3-small"
        self._selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self._embeddingProvider = EmbeddingProvider(rawValue: defaults.string(forKey: "embeddingProvider") ?? "") ?? .voyageAI
        self._voyageApiKey = ""
        self._suggestionVerbosity = SuggestionVerbosity(
            rawValue: defaults.string(forKey: "suggestionVerbosity") ?? ""
        ) ?? .quiet
        self._enableLiveTranscriptCleanup = defaults.bool(forKey: "enableLiveTranscriptCleanup")
        self._realtimeModel = defaults.string(forKey: "realtimeModel") ?? "google/gemini-3.1-flash-lite-preview"
        self._realtimeOllamaModel = defaults.string(forKey: "realtimeOllamaModel") ?? ""
        if defaults.object(forKey: "suggestionPanelEnabled") == nil {
            self._suggestionPanelEnabled = true
        } else {
            self._suggestionPanelEnabled = defaults.bool(forKey: "suggestionPanelEnabled")
        }
        if defaults.object(forKey: "suggestionsAlwaysOnTop") == nil {
            self._suggestionsAlwaysOnTop = true
        } else {
            self._suggestionsAlwaysOnTop = defaults.bool(forKey: "suggestionsAlwaysOnTop")
        }
        self._sidebarMode = SidebarMode(rawValue: defaults.string(forKey: "sidebarMode") ?? "") ?? .classicSuggestions
        self._sidecastIntensity = SidecastIntensity(rawValue: defaults.string(forKey: "sidecastIntensity") ?? "") ?? .balanced
        self._sidecastPersonas = Self.decodePersonas(defaults.data(forKey: "sidecastPersonas")) ?? SidecastPersona.starterPack
        self._sidecastTemperature = defaults.object(forKey: "sidecastTemperature") != nil
            ? defaults.double(forKey: "sidecastTemperature") : 1.0
        self._sidecastMaxTokens = defaults.object(forKey: "sidecastMaxTokens") != nil
            ? defaults.integer(forKey: "sidecastMaxTokens") : 700
        self._sidecastSystemPrompt = defaults.string(forKey: "sidecastSystemPrompt") ?? ""
        self._sidecastMinValueThreshold = defaults.object(forKey: "sidecastMinValueThreshold") != nil
            ? defaults.double(forKey: "sidecastMinValueThreshold") : 0.5
        self._preFetchIntervalSeconds = defaults.object(forKey: "preFetchIntervalSeconds") != nil
            ? defaults.double(forKey: "preFetchIntervalSeconds") : 4.0
        self._kbSimilarityThreshold = defaults.object(forKey: "kbSimilarityThreshold") != nil
            ? defaults.double(forKey: "kbSimilarityThreshold") : 0.35

        // Capture Settings
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._outputDeviceID = AudioDeviceID(defaults.integer(forKey: "outputDeviceID"))
        // Seed stable UIDs for users upgrading from an older version.
        let savedInputID = _inputDeviceID
        let savedOutputID = _outputDeviceID
        if savedInputID > 0, defaults.string(forKey: "inputDeviceUID") == nil {
            if let uid = MicCapture.deviceUID(for: savedInputID) { defaults.set(uid, forKey: "inputDeviceUID") }
            let name = MicCapture.availableInputDevices().first(where: { $0.id == savedInputID })?.name
            if let name { defaults.set(name, forKey: "inputDeviceName") }
        }
        if savedOutputID > 0, defaults.string(forKey: "outputDeviceUID") == nil {
            if let uid = try? SystemAudioCapture.outputDeviceUID(for: savedOutputID) { defaults.set(uid, forKey: "outputDeviceUID") }
            let name = SystemAudioCapture.availableOutputDevices().first(where: { $0.id == savedOutputID })?.name
            if let name { defaults.set(name, forKey: "outputDeviceName") }
        }
        self._transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .parakeetV2
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self._transcriptionCustomVocabulary = defaults.string(forKey: "transcriptionCustomVocabulary") ?? ""
        self._removeFillerWords = defaults.bool(forKey: "removeFillerWords")
        self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")

        if defaults.object(forKey: "enableEchoCancellation") == nil {
            self._enableEchoCancellation = true
        } else {
            self._enableEchoCancellation = defaults.bool(forKey: "enableEchoCancellation")
        }

        if defaults.object(forKey: "enableBatchRetranscription") == nil {
            self._enableBatchRetranscription = false
        } else {
            self._enableBatchRetranscription = defaults.bool(forKey: "enableBatchRetranscription")
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
        self._hasShownCameraDetectExplanation = defaults.bool(forKey: "hasShownCameraDetectExplanation")
        self._calendarIntegrationEnabled = defaults.bool(forKey: "calendarIntegrationEnabled")
        self._shareCalendarContextWithCloudNotes = defaults.bool(forKey: "shareCalendarContextWithCloudNotes")

        // Privacy Settings
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = true
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Import Settings
        self._granolaApiKey = ""

        // Apple Notes Settings
        self._appleNotesEnabled = defaults.bool(forKey: "appleNotesEnabled")
        if defaults.object(forKey: "appleNotesIncludeTranscript") == nil {
            self._appleNotesIncludeTranscript = true
        } else {
            self._appleNotesIncludeTranscript = defaults.bool(forKey: "appleNotesIncludeTranscript")
        }
        self._appleNotesFolderName = defaults.string(forKey: "appleNotesFolderName") ?? "OpenOats"
        self._appleNotesAccountName = defaults.string(forKey: "appleNotesAccountName") ?? "iCloud"
        if defaults.object(forKey: "appleNotesAutoExport") == nil {
            self._appleNotesAutoExport = false
        } else {
            self._appleNotesAutoExport = defaults.bool(forKey: "appleNotesAutoExport")
        }

        // Webhook Settings
        self._webhookEnabled = defaults.bool(forKey: "webhookEnabled")
        self._webhookURL = defaults.string(forKey: "webhookURL") ?? ""
        self._webhookSecret = ""

        // UI Settings
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }
        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._notesFolders = Self.decodeNotesFolders(defaults.data(forKey: "notesFolders")) ?? []
        self._meetingPrepNotesByKey = Self.decodeMeetingPrepNotes(defaults.data(forKey: "meetingPrepNotesByKey")) ?? [:]
        self._meetingHistoryAliasesByKey = Self.decodeMeetingHistoryAliases(
            defaults.data(forKey: "meetingHistoryAliasesByKey")
        ) ?? [:]
        self._meetingFamilyPreferencesByKey = Self.decodeMeetingFamilyPreferences(
            defaults.data(forKey: "meetingFamilyPreferencesByKey")
        ) ?? [:]
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

    /// Returns the cloud ASR API key for the current transcription model.
    var cloudASRApiKey: String {
        switch transcriptionModel {
        case .assemblyAI: assemblyAIApiKey
        case .elevenLabsScribe: elevenLabsApiKey
        default: ""
        }
    }

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

    private static func encodeNotesFolders(_ folders: [NotesFolderDefinition]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(folders)
    }

    private static func decodeNotesFolders(_ data: Data?) -> [NotesFolderDefinition]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([NotesFolderDefinition].self, from: data)
    }

    private static func normalizeNotesFolders(_ folders: [NotesFolderDefinition]) -> [NotesFolderDefinition] {
        var seen = Set<String>()
        var result: [NotesFolderDefinition] = []
        for folder in folders {
            guard let normalizedPath = NotesFolderDefinition.normalizePath(folder.path) else { continue }
            let key = normalizedPath.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(NotesFolderDefinition(id: folder.id, path: normalizedPath, color: folder.color))
        }
        return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func encodeMeetingPrepNotes(_ notes: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(notes)
    }

    private static func decodeMeetingPrepNotes(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func encodeMeetingHistoryAliases(_ aliases: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(aliases)
    }

    private static func decodeMeetingHistoryAliases(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func encodeMeetingFamilyPreferences(_ preferences: [String: MeetingFamilyPreferences]) -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(preferences)
    }

    private static func decodeMeetingFamilyPreferences(_ data: Data?) -> [String: MeetingFamilyPreferences]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: MeetingFamilyPreferences].self, from: data)
    }

    private static func normalizeMeetingPrepNotes(_ notes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in notes {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { continue }
            guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result[normalizedKey] = rawValue
        }
        return result
    }

    private static func normalizeMeetingHistoryAliases(_ aliases: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in aliases {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, !normalizedValue.isEmpty, normalizedKey != normalizedValue else {
                continue
            }
            result[normalizedKey] = normalizedValue
        }
        return result
    }

    private static func normalizeMeetingFamilyPreferences(
        _ preferences: [String: MeetingFamilyPreferences]
    ) -> [String: MeetingFamilyPreferences] {
        var result: [String: MeetingFamilyPreferences] = [:]
        for (rawKey, rawValue) in preferences {
            let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { continue }
            let normalizedValue = MeetingFamilyPreferences(
                templateID: rawValue.templateID,
                folderPath: normalizeMeetingFamilyFolderPath(rawValue.folderPath)
            )
            guard !normalizedValue.isEmpty else { continue }
            result[normalizedKey] = normalizedValue
        }
        return result
    }

    private static func normalizeMeetingFamilyFolderPath(_ folderPath: String?) -> String? {
        guard let normalized = NotesFolderDefinition.normalizePath(folderPath ?? "") else { return nil }
        let componentCount = normalized.split(separator: "/").count
        guard componentCount <= 2 else { return nil }
        return normalized
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
            if let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
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
            if let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
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
            if let oldValue = loadKeychain(service: oldService, key: key) {
                KeychainHelper.saveIfMissing(key: key, value: oldValue)
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
