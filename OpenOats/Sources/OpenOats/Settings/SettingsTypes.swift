import Foundation

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

/// LS-EEND diarization model variant.
enum DiarizationVariant: String, CaseIterable, Identifiable {
    case ami
    case callhome
    case dihard3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ami: "AMI (In-person, 4 speakers)"
        case .callhome: "CALLHOME (Phone, 7 speakers)"
        case .dihard3: "DIHARD III (General, 10 speakers)"
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
