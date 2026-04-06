import Foundation

/// JSON format exported by the sidecast debug tool for importing into the app.
struct SidecastPreset: Decodable {
    let version: Int
    let llmProvider: String?
    let apiKey: String?
    let baseURL: String?
    let model: String?
    let temperature: Double?
    let maxTokens: Int?
    let intensity: String?
    let systemPromptTemplate: String?
    let minValueThreshold: Double?
    let windowSize: Int?
    let summaryRefreshInterval: Int?
    let webSearchEngine: String?
    let webSearchMaxResults: Int?
    let personas: [PresetPersona]?

    struct PresetPersona: Decodable {
        let name: String
        let subtitle: String
        let prompt: String
        let avatarTint: String
        let avatarEmoji: String?
        let verbosity: String
        let cadence: String
        let evidencePolicy: String
        let isEnabled: Bool
        let webSearchEnabled: Bool

        func toSidecastPersona() -> SidecastPersona {
            SidecastPersona(
                name: name,
                subtitle: subtitle,
                prompt: prompt,
                avatarSymbol: Self.symbolForEmoji(avatarEmoji) ?? Self.symbolForName(name),
                avatarTint: PersonaAvatarTint(rawValue: avatarTint) ?? .blue,
                verbosity: PersonaVerbosity(rawValue: verbosity) ?? .short,
                cadence: PersonaCadence(rawValue: cadence) ?? .normal,
                evidencePolicy: PersonaEvidencePolicy(rawValue: evidencePolicy) ?? .optional,
                isEnabled: isEnabled,
                webSearchEnabled: webSearchEnabled
            )
        }

        private static let emojiToSymbol: [String: String] = [
            "\u{2714}\u{FE0F}": "checkmark.seal.fill",
            "\u{1F4DA}": "books.vertical.fill",
            "\u{26A1}": "bolt.fill",
            "\u{1F525}": "exclamationmark.bubble.fill",
            "\u{1F3AF}": "scope",
            "\u{1F4A1}": "lightbulb.fill",
            "\u{1F52D}": "eye.fill",
            "\u{1F3AD}": "theatermasks.fill",
            "\u{1F9E0}": "brain.head.profile",
            "\u{1F441}\u{FE0F}": "eye.fill",
            "\u{1F6E1}\u{FE0F}": "shield.fill",
            "\u{1F3A9}": "sparkles",
        ]

        private static func symbolForEmoji(_ emoji: String?) -> String? {
            guard let emoji, !emoji.isEmpty else { return nil }
            return emojiToSymbol[emoji]
        }

        private static func symbolForName(_ name: String) -> String {
            let lower = name.lowercased()
            if lower.contains("check") { return "checkmark.seal.fill" }
            if lower.contains("archiv") { return "books.vertical.fill" }
            if lower.contains("snip") { return "bolt.fill" }
            if lower.contains("menace") || lower.contains("chaos") { return "exclamationmark.bubble.fill" }
            return "person.crop.circle.fill"
        }
    }

    /// Maps debug tool provider strings to app LLMProvider enum values.
    private static let providerMap: [String: LLMProvider] = [
        "openrouter": .openRouter,
        "ollama": .ollama,
        "openai-compatible": .openAICompatible,
    ]

    @MainActor func apply(to settings: AppSettings) {
        // LLM connection
        if let llmProvider, let mapped = Self.providerMap[llmProvider] {
            settings.llmProvider = mapped

            if let apiKey, !apiKey.isEmpty {
                switch mapped {
                case .openRouter:
                    settings.openRouterApiKey = apiKey
                case .openAICompatible:
                    settings.openAILLMApiKey = apiKey
                case .ollama, .mlx:
                    break
                }
            }

            if let baseURL, !baseURL.isEmpty {
                switch mapped {
                case .ollama:
                    settings.ollamaBaseURL = baseURL
                case .openAICompatible:
                    settings.openAILLMBaseURL = baseURL
                case .openRouter, .mlx:
                    break
                }
            }

            if let model, !model.isEmpty {
                switch mapped {
                case .openRouter:
                    settings.realtimeModel = model
                case .ollama:
                    settings.realtimeOllamaModel = model
                case .openAICompatible:
                    settings.openAILLMModel = model
                case .mlx:
                    settings.mlxModel = model
                }
            }
        }

        // Sidecast tuning
        if let temperature {
            settings.sidecastTemperature = temperature
        }
        if let maxTokens {
            settings.sidecastMaxTokens = maxTokens
        }
        if let intensity, let parsed = SidecastIntensity(rawValue: intensity) {
            settings.sidecastIntensity = parsed
        }
        if let systemPromptTemplate {
            settings.sidecastSystemPrompt = systemPromptTemplate
        }
        if let minValueThreshold {
            settings.sidecastMinValueThreshold = minValueThreshold
        }

        // Personas
        if let personas {
            settings.sidecastPersonas = personas.map { $0.toSidecastPersona() }
        }
    }
}
