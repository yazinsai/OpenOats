import AppKit
import Foundation
import Observation
import Security
import CoreAudio

/// Controls how eagerly the suggestion engine surfaces talking points.
enum SuggestionVerbosity: String, CaseIterable, Identifiable {
    /// Mostly silent — surfaces suggestions only when highly relevant (current default behavior).
    case quiet
    /// Balanced — moderate cooldown, slightly lower thresholds.
    case balanced
    /// Eager — short cooldown, lower thresholds for frequent fact-retrieval style use.
    case eager

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .eager: "Eager"
        }
    }

    var description: String {
        switch self {
        case .quiet: "Surfaces suggestions only when highly relevant"
        case .balanced: "Moderate frequency, good for most meetings"
        case .eager: "Frequent suggestions, good for fact retrieval"
        }
    }

    /// Seconds between consecutive suggestions.
    var cooldownSeconds: TimeInterval {
        switch self {
        case .quiet: 90
        case .balanced: 45
        case .eager: 15
        }
    }

    /// Multiplier applied to gate score thresholds. Lower = easier to surface.
    var thresholdMultiplier: Double {
        switch self {
        case .quiet: 1.0
        case .balanced: 0.85
        case .eager: 0.70
        }
    }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case openRouter
    case ollama
    case mlx
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .mlx: "MLX"
        case .openAICompatible: "OpenAI Compatible"
        }
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case parakeetV2
    case parakeetV3
    case qwen3ASR06B
    case whisperBase
    case whisperSmall
    case whisperLargeV3Turbo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV2: "Parakeet TDT v2"
        case .parakeetV3: "Parakeet TDT v3"
        case .qwen3ASR06B: "Qwen3 ASR 0.6B"
        case .whisperBase: "Whisper Base"
        case .whisperSmall: "Whisper Small"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    var downloadPrompt: String {
        switch self {
        case .parakeetV2, .parakeetV3:
            "Transcription requires a one-time model download."
        case .qwen3ASR06B:
            "Qwen3 ASR requires a one-time model download."
        case .whisperBase:
            "Whisper Base requires a one-time model download (~142 MB)."
        case .whisperSmall:
            "Whisper Small requires a one-time model download (~244 MB)."
        case .whisperLargeV3Turbo:
            "Whisper Large v3 Turbo requires a one-time model download (~800 MB)."
        }
    }

    var supportsExplicitLanguageHint: Bool {
        switch self {
        case .qwen3ASR06B:
            true
        case .parakeetV2, .parakeetV3, .whisperBase, .whisperSmall, .whisperLargeV3Turbo:
            false
        }
    }

    var localeFieldTitle: String {
        switch self {
        case .qwen3ASR06B:
            "Language Hint"
        case .parakeetV2, .parakeetV3, .whisperBase, .whisperSmall, .whisperLargeV3Turbo:
            "Locale"
        }
    }

    var localeHelpText: String {
        switch self {
        case .parakeetV2:
            "Parakeet TDT v2 is English-only. Locale changes do not affect this model."
        case .parakeetV3:
            "Parakeet TDT v3 auto-detects among its supported languages. Locale changes do not affect this model."
        case .qwen3ASR06B:
            "Optional. Used as a language hint for Qwen3 ASR. Enter a locale such as en-US, fr-FR, or ja-JP. Applies when a new session starts."
        case .whisperBase, .whisperSmall:
            "Whisper auto-detects the spoken language. Locale changes do not affect this model."
        case .whisperLargeV3Turbo:
            "Whisper Large v3 Turbo auto-detects the spoken language. Best multilingual batch model."
        }
    }

    /// The WhisperKit model variant, if this is a Whisper-based model.
    var whisperVariant: WhisperKitManager.Variant? {
        switch self {
        case .whisperBase: .base
        case .whisperSmall: .small
        case .whisperLargeV3Turbo: .largeV3Turbo
        default: nil
        }
    }

    func makeBackend(customVocabulary: String = "") -> any TranscriptionBackend {
        switch self {
        case .parakeetV2: return ParakeetBackend(version: .v2, customVocabulary: customVocabulary)
        case .parakeetV3: return ParakeetBackend(version: .v3, customVocabulary: customVocabulary)
        case .qwen3ASR06B: return Qwen3Backend()
        case .whisperBase: return WhisperKitBackend(variant: .base)
        case .whisperSmall: return WhisperKitBackend(variant: .small)
        case .whisperLargeV3Turbo: return WhisperKitBackend(variant: .largeV3Turbo)
        }
    }

    /// Models suitable for offline batch re-transcription.
    /// Excludes Parakeet (English-focused streaming models).
    static var batchSuitableModels: [TranscriptionModel] {
        [.whisperSmall, .whisperLargeV3Turbo, .qwen3ASR06B]
    }
}

enum EmbeddingProvider: String, CaseIterable, Identifiable {
    case voyageAI
    case ollama
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voyageAI: "Voyage AI"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI Compatible"
        }
    }
}

struct AppSecretStore: Sendable {
    let loadValue: @Sendable (String) -> String?
    let saveValue: @Sendable (String, String) -> Void

    func load(key: String) -> String? {
        loadValue(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    static let keychain = AppSecretStore(
        loadValue: { KeychainHelper.load(key: $0) },
        saveValue: { key, value in
            KeychainHelper.save(key: key, value: value)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct AppSettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> AppSettingsStorage {
        AppSettingsStorage(
            defaults: defaults,
            secretStore: .keychain,
            defaultNotesDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/OpenOats"),
            runMigrations: true
        )
    }
}

@Observable
@MainActor
final class AppSettings {
    private let defaults: UserDefaults
    private let secretStore: AppSecretStore

    // SwiftUI can evaluate view bodies outside a MainActor executor context in
    // Swift 6.2. Use nonisolated backing storage plus manual observation
    // tracking so bound settings remain safe to read during those updates.
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

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
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

    /// Whether the user has acknowledged their obligation to comply with recording consent laws.
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

    /// When false, the live transcript panel is hidden during recording to save resources.
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

    /// When true, a local .m4a audio file is saved alongside each transcript.
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

    /// When true, Apple's voice-processing IO is enabled on the mic input to cancel
    /// speaker echo and reduce double-transcription when using built-in speakers + mic.
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

    /// When true, uses the LLM to clean up filler words and fix punctuation in real-time.
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

    /// When true, re-transcribes audio with a higher-quality model after each meeting.
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

    /// The model used for offline batch re-transcription after meetings.
    /// WARNING: WhisperKit large-v3 CoreML (NOT turbo) is unsuitable for non-English
    /// batch work (69.6% WER in benchmarks). Use large-v3-turbo instead.
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

    /// When true, all app windows are invisible to screen sharing / recording.
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

    // MARK: - Meeting Detection

    /// Whether automatic meeting detection is enabled.
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

    /// Whether the explanation sheet for auto-detect has been shown.
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

    /// Whether the user has seen the suggestion to enable Launch at Login.
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

    /// Minutes of mic silence before auto-stopping a detected session.
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

    /// User-added meeting app bundle IDs beyond the built-in list.
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

    /// When true, detection events are logged to the console.
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

    // MARK: - Suggestions

    /// How eagerly the suggestion engine surfaces talking points.
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

    init(storage: AppSettingsStorage = .live()) {
        self.defaults = storage.defaults
        self.secretStore = storage.secretStore

        let defaults = storage.defaults

        // One-time migrations from previous bundle IDs
        if storage.runMigrations {
            Self.migrateFromOldBundleIfNeeded(defaults: defaults)
            Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)
            Self.migrateKeychainServiceIfNeeded(defaults: defaults)
        }

        self._kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""

        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "en-US"
        self._transcriptionCustomVocabulary = defaults.string(forKey: "transcriptionCustomVocabulary") ?? ""
        self._transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .parakeetV2
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._openRouterApiKey = secretStore.load(key: "openRouterApiKey") ?? ""
        self._voyageApiKey = secretStore.load(key: "voyageApiKey") ?? ""
        self._llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self._embeddingProvider = EmbeddingProvider(rawValue: defaults.string(forKey: "embeddingProvider") ?? "") ?? .voyageAI
        self._ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self._ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self._ollamaEmbedModel = defaults.string(forKey: "ollamaEmbedModel") ?? "nomic-embed-text"
        self._mlxBaseURL = defaults.string(forKey: "mlxBaseURL") ?? "http://localhost:8080"
        self._mlxModel = defaults.string(forKey: "mlxModel") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        self._openAILLMBaseURL = defaults.string(forKey: "openAILLMBaseURL") ?? "http://localhost:4000"
        self._openAILLMApiKey = secretStore.load(key: "openAILLMApiKey") ?? ""
        self._openAILLMModel = defaults.string(forKey: "openAILLMModel") ?? ""
        self._openAIEmbedBaseURL = defaults.string(forKey: "openAIEmbedBaseURL") ?? "http://localhost:8080"
        self._openAIEmbedApiKey = secretStore.load(key: "openAIEmbedApiKey") ?? ""
        self._openAIEmbedModel = defaults.string(forKey: "openAIEmbedModel") ?? "text-embedding-3-small"
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")
        self._enableTranscriptRefinement = defaults.bool(forKey: "enableTranscriptRefinement")
        // Default to enabled if key has never been set
        if defaults.object(forKey: "enableBatchRefinement") == nil {
            self._enableBatchRefinement = true
        } else {
            self._enableBatchRefinement = defaults.bool(forKey: "enableBatchRefinement")
        }
        self._batchTranscriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "batchTranscriptionModel") ?? ""
        ) ?? .whisperLargeV3Turbo

        // Echo cancellation — default to enabled
        if defaults.object(forKey: "enableEchoCancellation") == nil {
            self._enableEchoCancellation = true
        } else {
            self._enableEchoCancellation = defaults.bool(forKey: "enableEchoCancellation")
        }

        // Default to true (shown) if key has never been set
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }

        // Meeting detection — default to enabled
        if defaults.object(forKey: "meetingAutoDetectEnabled") == nil {
            self._meetingAutoDetectEnabled = true
        } else {
            self._meetingAutoDetectEnabled = defaults.bool(forKey: "meetingAutoDetectEnabled")
        }
        self._hasShownAutoDetectExplanation = defaults.bool(forKey: "hasShownAutoDetectExplanation")
        self._hasSeenLaunchAtLoginSuggestion = defaults.bool(forKey: "hasSeenLaunchAtLoginSuggestion")
        self._silenceTimeoutMinutes = defaults.object(forKey: "silenceTimeoutMinutes") != nil
            ? defaults.integer(forKey: "silenceTimeoutMinutes") : 15
        self._customMeetingAppBundleIDs = defaults.stringArray(forKey: "customMeetingAppBundleIDs") ?? []
        self._detectionLogEnabled = defaults.bool(forKey: "detectionLogEnabled")
        self._suggestionVerbosity = SuggestionVerbosity(
            rawValue: defaults.string(forKey: "suggestionVerbosity") ?? ""
        ) ?? .quiet

        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = true
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

        // Prevent Spotlight from indexing transcript contents
        Self.dropMetadataNeverIndex(atPath: notesFolderPath)
    }

    /// Place a .metadata_never_index sentinel so Spotlight skips the directory.
    private static func dropMetadataNeverIndex(atPath directoryPath: String) {
        let sentinel = URL(fileURLWithPath: directoryPath).appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults and Keychain entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // Migrate UserDefaults from old bundle
        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // Migrate Keychain entries from old service
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

        // --- Migrate UserDefaults ---
        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            // Even without old defaults, migrate file-backed state
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "kbFolderPath", "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "embeddingProvider", "ollamaBaseURL", "ollamaLLMModel",
            "ollamaEmbedModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // --- Migrate Keychain ---
        let oldService = "com.opengranola.app"
        let keychainKeys = ["openRouterApiKey", "voyageApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }

        // --- Migrate file-backed state ---
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

        // Migrate Application Support: sessions/, templates.json, kb_cache.json
        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            // Sessions directory (JSONL files + sidecars)
            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            // Templates
            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }

            // KB embedding cache
            let oldCache = oldAppSupportDir.appendingPathComponent("kb_cache.json")
            let newCache = newAppSupportDir.appendingPathComponent("kb_cache.json")
            if fm.fileExists(atPath: oldCache.path) && !fm.fileExists(atPath: newCache.path) {
                try? fm.moveItem(at: oldCache, to: newCache)
            }
        }

        // KB folder: leave unset by default. Only preserve an explicitly-set path
        // that pointed at the old OpenGranola directory (user chose it themselves).
        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir = home.appendingPathComponent("Documents/OpenOats")

        // Migrate notes folder: if the old default directory has content,
        // use it as the notes folder so transcript archives stay accessible.
        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        // Migrate transcript archives: move files from ~/Documents/OpenGranola/
        // into ~/Documents/OpenOats/ so new sessions and old archives coexist.
        // Skip if the old dir is the active KB folder or notes folder (files stay in place).
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
    /// current "com.openoats.app" service. Needed for existing users whose keychain
    /// was written under the previous bundle ID.
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

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
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

}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.openoats.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
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

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
