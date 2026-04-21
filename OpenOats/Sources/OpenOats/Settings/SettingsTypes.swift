import Foundation

enum NotesFolderColor: String, CaseIterable, Identifiable, Codable {
    case gray
    case orange
    case gold
    case purple
    case blue
    case teal
    case green
    case red

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

struct NotesFolderDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var path: String
    var color: NotesFolderColor

    init(id: UUID = UUID(), path: String, color: NotesFolderColor) {
        self.id = id
        self.path = Self.normalizePath(path) ?? path
        self.color = color
    }

    var displayName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var breadcrumb: String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: " › ")
    }

    static func normalizePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}

struct MeetingFamilyPreferences: Codable, Equatable, Sendable {
    var templateID: UUID?
    var folderPath: String?

    var isEmpty: Bool {
        templateID == nil && folderPath == nil
    }
}

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

enum SidebarMode: String, CaseIterable, Identifiable {
    case classicSuggestions
    case sidecast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicSuggestions: "Classic"
        case .sidecast: "Sidecast"
        }
    }

    var description: String {
        switch self {
        case .classicSuggestions: "Single-stream KB-backed suggestions"
        case .sidecast: "Multi-persona sidebar with avatar bubbles"
        }
    }
}

enum SidecastIntensity: String, CaseIterable, Identifiable {
    case quiet
    case balanced
    case lively

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .lively: "Lively"
        }
    }

    var description: String {
        switch self {
        case .quiet: "Strict throttling. Only the strongest persona messages appear."
        case .balanced: "Useful defaults for most host-assist sessions."
        case .lively: "More reactive, but still capped to avoid spam."
        }
    }

    var maxMessagesPerTurn: Int {
        switch self {
        case .quiet: 1
        case .balanced: 2
        case .lively: 10 // effectively unlimited — show all personas
        }
    }

    var generationCooldownSeconds: TimeInterval {
        switch self {
        case .quiet: 18
        case .balanced: 10
        case .lively: 0 // no cooldown — fire on every utterance
        }
    }

    var bubbleLifetimeSeconds: TimeInterval {
        switch self {
        case .quiet: 16
        case .balanced: 20
        case .lively: 30
        }
    }

    /// Whether per-persona cadence cooldowns should be skipped.
    var skipPersonaCooldowns: Bool {
        self == .lively
    }
}

enum PersonaVerbosity: String, CaseIterable, Identifiable, Codable {
    case terse
    case short
    case medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terse: "Terse"
        case .short: "Short"
        case .medium: "Medium"
        }
    }

    var characterLimit: Int {
        switch self {
        case .terse: 80
        case .short: 140
        case .medium: 220
        }
    }
}

enum PersonaCadence: String, CaseIterable, Identifiable, Codable {
    case rare
    case normal
    case active

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rare: "Rare"
        case .normal: "Normal"
        case .active: "Active"
        }
    }

    var cooldownSeconds: TimeInterval {
        switch self {
        case .rare: 40
        case .normal: 24
        case .active: 14
        }
    }
}

enum PersonaEvidencePolicy: String, CaseIterable, Identifiable, Codable {
    case required
    case preferred
    case optional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .required: "Required"
        case .preferred: "Preferred"
        case .optional: "Optional"
        }
    }
}

enum PersonaAvatarTint: String, CaseIterable, Identifiable, Codable {
    case slate
    case blue
    case teal
    case green
    case orange
    case red
    case pink
    case indigo

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
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
    case assemblyAI
    case elevenLabsScribe

    var id: String { rawValue }

    var isCloud: Bool {
        switch self {
        case .assemblyAI, .elevenLabsScribe: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .parakeetV2: "Parakeet TDT v2"
        case .parakeetV3: "Parakeet TDT v3"
        case .qwen3ASR06B: "Qwen3 ASR 0.6B"
        case .whisperBase: "Whisper Base"
        case .whisperSmall: "Whisper Small"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        case .assemblyAI: "AssemblyAI"
        case .elevenLabsScribe: "ElevenLabs Scribe"
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
        case .assemblyAI, .elevenLabsScribe:
            "Requires an API key. Enter it in Settings > Transcription."
        }
    }

    /// Approximate total download size in bytes, used for progress display.
    /// Returns nil when the size is unknown.
    var estimatedDownloadBytes: Int64? {
        switch self {
        case .whisperBase: 142_000_000
        case .whisperSmall: 244_000_000
        case .whisperLargeV3Turbo: 800_000_000
        case .parakeetV2, .parakeetV3, .qwen3ASR06B: nil
        case .assemblyAI, .elevenLabsScribe: nil
        }
    }

    var supportsExplicitLanguageHint: Bool {
        true
    }

    var localeFieldTitle: String {
        switch self {
        case .qwen3ASR06B:
            "Language Hint"
        case .parakeetV2, .parakeetV3, .whisperBase, .whisperSmall, .whisperLargeV3Turbo:
            "Locale"
        case .assemblyAI, .elevenLabsScribe:
            "Language Hint"
        }
    }

    var localeHelpText: String {
        switch self {
        case .parakeetV2:
            "Parakeet TDT v2 is English-only. Use en-US. This language value is still saved with the session and markdown export."
        case .parakeetV3:
            "Parakeet TDT v3 auto-detects speech language. Use this field to set your expected meeting language for metadata and export."
        case .qwen3ASR06B:
            "Used as a language hint for Qwen3 ASR and saved with the session. Enter a locale such as en-US, fr-FR, or ja-JP."
        case .whisperBase, .whisperSmall:
            "Whisper auto-detects speech language. This setting is still saved with the session and markdown export."
        case .whisperLargeV3Turbo:
            "Whisper Large v3 Turbo auto-detects speech language. This setting is saved with session metadata and markdown export."
        case .assemblyAI:
            "Optional language hint for AssemblyAI. Leave as en-US for English or set to your expected meeting language."
        case .elevenLabsScribe:
            "Optional language hint for ElevenLabs Scribe. Leave empty for auto-detection (recommended for multilingual meetings), or set to a language code like en, fr, de."
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

    func makeBackend(customVocabulary: String = "", apiKey: String = "", removeFillerWords: Bool = false) -> any TranscriptionBackend {
        switch self {
        case .parakeetV2: return ParakeetBackend(version: .v2, customVocabulary: customVocabulary)
        case .parakeetV3: return ParakeetBackend(version: .v3, customVocabulary: customVocabulary)
        case .qwen3ASR06B: return Qwen3Backend()
        case .whisperBase: return WhisperKitBackend(variant: .base)
        case .whisperSmall: return WhisperKitBackend(variant: .small)
        case .whisperLargeV3Turbo: return WhisperKitBackend(variant: .largeV3Turbo)
        case .assemblyAI: return AssemblyAIBackend(apiKey: apiKey, customVocabulary: customVocabulary)
        case .elevenLabsScribe: return ElevenLabsScribeBackend(apiKey: apiKey, customVocabulary: customVocabulary, removeFillerWords: removeFillerWords)
        }
    }

    /// Flush interval in 16kHz samples for streaming transcription.
    /// Whisper models benefit from longer context windows (10s); Parakeet/Qwen are robust at 5s.
    var flushIntervalSamples: Int {
        switch self {
        case .whisperBase, .whisperSmall, .whisperLargeV3Turbo:
            10 * 16_000
        case .parakeetV2, .parakeetV3, .qwen3ASR06B:
            5 * 16_000
        case .assemblyAI, .elevenLabsScribe:
            10 * 16_000  // 10s - fewer API calls, better accuracy per segment
        }
    }

    /// Models suitable for offline batch re-transcription.
    static var batchSuitableModels: [TranscriptionModel] {
        [.parakeetV2, .parakeetV3, .whisperSmall, .whisperLargeV3Turbo, .qwen3ASR06B]
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
