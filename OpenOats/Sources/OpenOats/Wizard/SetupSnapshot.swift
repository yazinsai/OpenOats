import CoreAudio
import Foundation

/// Immutable snapshot of hardware and service detection results.
/// Produced by `SetupDetector`, consumed by `RecommendationEngine`.
struct SetupSnapshot: Sendable {
    /// Physical RAM in bytes.
    let physicalMemoryBytes: UInt64

    /// Derived RAM tier.
    var ramTier: RAMTier {
        RAMTier(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Primary system locale identifier, for example `en-US` or `de-DE`.
    let systemLocale: String

    /// Whether the system locale appears to be English.
    var isEnglishLocale: Bool {
        systemLocale.lowercased().hasPrefix("en")
    }

    /// Available audio input devices.
    let audioDevices: [(id: AudioDeviceID, name: String)]

    /// Microphone permission status at detection time.
    let micPermission: MicPermissionStatus

    /// Backend status for each transcription model.
    let modelStatuses: [TranscriptionModel: BackendStatus]

    /// Whether an OpenRouter API key was found in existing settings.
    let hasOpenRouterKey: Bool

    /// Whether a Voyage AI API key was found in existing settings.
    let hasVoyageKey: Bool

    /// Whether an AssemblyAI API key was found in existing settings.
    let hasAssemblyAIKey: Bool

    /// Whether an ElevenLabs API key was found in existing settings.
    let hasElevenLabsKey: Bool

    /// Whether a Cohere API key was found in existing settings.
    let hasCohereKey: Bool

    /// Existing OpenRouter API key value for pre-populating fields.
    let existingOpenRouterKey: String

    /// Existing Voyage AI API key value for pre-populating fields.
    let existingVoyageKey: String

    /// Existing AssemblyAI API key value for pre-populating fields.
    let existingAssemblyAIKey: String

    /// Existing ElevenLabs API key value for pre-populating fields.
    let existingElevenLabsKey: String

    /// Existing Cohere API key value for pre-populating fields.
    let existingCohereKey: String

    /// Ollama probe result.
    let ollamaResult: Result<[String], OllamaModelFetcher.FetchError>

    /// Whether Ollama was reachable and returned models.
    var ollamaReachable: Bool {
        if case .success = ollamaResult {
            return true
        }
        return false
    }

    /// Models currently available in Ollama.
    var ollamaModels: [String] {
        if case .success(let models) = ollamaResult {
            return models
        }
        return []
    }

    /// Determine whether Ollama has all required models.
    func ollamaHasModels(_ required: [String]) -> Bool {
        let available = Set(ollamaModels.map { $0.lowercased() })
        return required.allSatisfy { model in
            let lower = model.lowercased()
            let prefix = lower.split(separator: ":").first.map(String.init) ?? lower
            return available.contains(lower) || available.contains(where: { $0.hasPrefix(prefix) })
        }
    }

    /// Determine Ollama status relative to a required model list.
    func ollamaStatus(requiredModels: [String]) -> OllamaStatus {
        guard ollamaReachable else {
            return .notReachable
        }

        let available = Set(ollamaModels.map { $0.lowercased() })
        let missing = requiredModels.filter { model in
            let lower = model.lowercased()
            let prefix = lower.split(separator: ":").first.map(String.init) ?? lower
            return !available.contains(lower) && !available.contains(where: { $0.hasPrefix(prefix) })
        }

        if missing.isEmpty {
            return .readyWithModels
        }
        return .missingModels(missing: missing)
    }

    /// Default snapshot for previews and tests before real detection has completed.
    static let empty = SetupSnapshot(
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        systemLocale: "en-US",
        audioDevices: [],
        micPermission: .notDetermined,
        modelStatuses: [:],
        hasOpenRouterKey: false,
        hasVoyageKey: false,
        hasAssemblyAIKey: false,
        hasElevenLabsKey: false,
        hasCohereKey: false,
        existingOpenRouterKey: "",
        existingVoyageKey: "",
        existingAssemblyAIKey: "",
        existingElevenLabsKey: "",
        existingCohereKey: "",
        ollamaResult: .failure(.networkError("not probed"))
    )
}
