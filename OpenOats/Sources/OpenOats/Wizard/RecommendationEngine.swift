import Foundation

/// Pure-function recommendation engine. No side effects, no async, fully testable.
enum RecommendationEngine {
    /// Maps user answers and the detection snapshot to a complete recommendation.
    static func recommend(
        intent: WizardIntent,
        language: WizardLanguage,
        privacy: WizardPrivacy,
        snapshot: SetupSnapshot
    ) -> WizardRecommendation {
        let profile = resolveProfile(intent: intent, language: language, privacy: privacy, ramTier: snapshot.ramTier)
        return buildRecommendation(profile: profile, intent: intent, snapshot: snapshot)
    }

    // MARK: - Profile Resolution

    /// Decision matrix: `(language, privacy, RAM)` to profile.
    static func resolveProfile(
        intent: WizardIntent,
        language: WizardLanguage,
        privacy: WizardPrivacy,
        ramTier: RAMTier
    ) -> WizardProfile {
        switch intent {
        case .transcribe:
            switch language {
            case .english:
                return .transcriptEN
            case .multilingual:
                return .transcriptMulti
            }

        case .notes, .fullCopilot:
            switch (language, privacy, ramTier) {
            case (.english, .cloud, _):
                return .cloudEN
            case (.multilingual, .cloud, _):
                return .cloudMulti
            case (.english, .local, .low):
                return .localENLight
            case (.english, .local, .high):
                return .localENFull
            case (.multilingual, .local, .low):
                return .localMultiLight
            case (.multilingual, .local, .high):
                return .localMultiFull
            }
        }
    }

    // MARK: - Recommendation Building

    private static func buildRecommendation(
        profile: WizardProfile,
        intent: WizardIntent,
        snapshot: SetupSnapshot
    ) -> WizardRecommendation {
        let transcription = transcriptionConfig(for: profile, ramTier: snapshot.ramTier)
        let llm = llmConfig(for: profile)
        let embedding = embeddingConfig(for: profile, intent: intent)
        let defaults = defaultsConfig(for: profile)
        let requiredModels = requiredOllamaModels(for: profile, intent: intent)
        let display = displayConfig(for: profile, intent: intent, transcriptionModel: transcription.model)

        return WizardRecommendation(
            profile: profile,
            transcriptionModel: transcription.model,
            transcriptionLocale: transcription.locale,
            llmProvider: llm.provider,
            selectedModel: llm.selectedModel,
            realtimeModel: llm.realtimeModel,
            ollamaBaseURL: llm.ollamaBaseURL,
            ollamaLLMModel: llm.ollamaLLMModel,
            ollamaEmbedModel: embedding.ollamaEmbedModel,
            embeddingProvider: embedding.provider,
            suggestionPanelEnabled: intent == .fullCopilot,
            suggestionVerbosity: defaults.verbosity,
            sidebarMode: defaults.sidebarMode,
            sidecastIntensity: defaults.sidecastIntensity,
            requiredOllamaModels: requiredModels,
            summaryLine: display.summary,
            detailLines: display.details,
            estimatedDownloadBytes: estimateDownloadSize(
                transcription: transcription.model,
                profile: profile,
                requiredOllamaModels: requiredModels
            )
        )
    }

    // MARK: - Transcription

    private struct TranscriptionConfig {
        let model: TranscriptionModel
        let locale: String
    }

    private static func transcriptionConfig(for profile: WizardProfile, ramTier: RAMTier) -> TranscriptionConfig {
        switch profile {
        case .transcriptEN, .cloudEN, .localENLight, .localENFull:
            return TranscriptionConfig(model: .parakeetV2, locale: "en-US")
        case .transcriptMulti:
            return TranscriptionConfig(model: .parakeetV3, locale: "")
        case .cloudMulti:
            switch ramTier {
            case .low:
                return TranscriptionConfig(model: .whisperSmall, locale: "")
            case .high:
                return TranscriptionConfig(model: .whisperLargeV3Turbo, locale: "")
            }
        case .localMultiLight:
            return TranscriptionConfig(model: .whisperSmall, locale: "")
        case .localMultiFull:
            return TranscriptionConfig(model: .whisperLargeV3Turbo, locale: "")
        }
    }

    // MARK: - LLM

    private struct LLMConfig {
        let provider: LLMProvider?
        let selectedModel: String?
        let realtimeModel: String?
        let ollamaBaseURL: String?
        let ollamaLLMModel: String?
    }

    private static func llmConfig(for profile: WizardProfile) -> LLMConfig {
        switch profile {
        case .transcriptEN, .transcriptMulti:
            return LLMConfig(
                provider: nil,
                selectedModel: nil,
                realtimeModel: nil,
                ollamaBaseURL: nil,
                ollamaLLMModel: nil
            )

        case .cloudEN, .cloudMulti:
            return LLMConfig(
                provider: .openRouter,
                selectedModel: "google/gemini-3-flash-preview",
                realtimeModel: "google/gemini-3.1-flash-lite-preview",
                ollamaBaseURL: nil,
                ollamaLLMModel: nil
            )

        case .localENLight, .localMultiLight:
            return LLMConfig(
                provider: .ollama,
                selectedModel: nil,
                realtimeModel: nil,
                ollamaBaseURL: "http://localhost:11434",
                ollamaLLMModel: "phi3.5:3.8b-mini-q4_K_M"
            )

        case .localENFull, .localMultiFull:
            return LLMConfig(
                provider: .ollama,
                selectedModel: nil,
                realtimeModel: nil,
                ollamaBaseURL: "http://localhost:11434",
                ollamaLLMModel: "qwen3:8b"
            )
        }
    }

    // MARK: - Embedding

    private struct EmbeddingConfig {
        let provider: EmbeddingProvider?
        let ollamaEmbedModel: String?
    }

    private static func embeddingConfig(for profile: WizardProfile, intent: WizardIntent) -> EmbeddingConfig {
        guard intent == .fullCopilot else {
            return EmbeddingConfig(provider: nil, ollamaEmbedModel: nil)
        }

        switch profile {
        case .cloudEN, .cloudMulti:
            return EmbeddingConfig(provider: .voyageAI, ollamaEmbedModel: nil)
        case .localENLight, .localENFull, .localMultiLight, .localMultiFull:
            return EmbeddingConfig(provider: .ollama, ollamaEmbedModel: "nomic-embed-text")
        case .transcriptEN, .transcriptMulti:
            return EmbeddingConfig(provider: nil, ollamaEmbedModel: nil)
        }
    }

    // MARK: - Defaults

    private struct DefaultsConfig {
        let verbosity: SuggestionVerbosity
        let sidebarMode: SidebarMode
        let sidecastIntensity: SidecastIntensity
    }

    private static func defaultsConfig(for profile: WizardProfile) -> DefaultsConfig {
        let intensity: SidecastIntensity
        switch profile {
        case .localENLight, .localMultiLight:
            intensity = .quiet
        default:
            intensity = .balanced
        }

        return DefaultsConfig(
            verbosity: .balanced,
            sidebarMode: .classicSuggestions,
            sidecastIntensity: intensity
        )
    }

    // MARK: - Ollama Requirements

    static func requiredOllamaModels(for profile: WizardProfile, intent: WizardIntent) -> [String] {
        var models: [String] = []

        switch profile {
        case .localENLight, .localMultiLight:
            models.append("phi3.5:3.8b-mini-q4_K_M")
        case .localENFull, .localMultiFull:
            models.append("qwen3:8b")
        default:
            break
        }

        if intent == .fullCopilot && profile.isLocal {
            models.append("nomic-embed-text")
        }

        return models
    }

    // MARK: - Download Size

    private static func estimateDownloadSize(
        transcription: TranscriptionModel,
        profile: WizardProfile,
        requiredOllamaModels: [String]
    ) -> Int64 {
        var total: Int64 = transcription.estimatedDownloadBytes ?? 0

        switch profile {
        case .localENLight, .localMultiLight:
            total += 2_200_000_000
        case .localENFull, .localMultiFull:
            total += 4_700_000_000
        default:
            break
        }

        if requiredOllamaModels.contains("nomic-embed-text") {
            total += 275_000_000
        }

        return total
    }

    // MARK: - Display Strings

    private struct DisplayConfig {
        let summary: String
        let details: [String]
    }

    private static func displayConfig(
        for profile: WizardProfile,
        intent: WizardIntent,
        transcriptionModel: TranscriptionModel
    ) -> DisplayConfig {
        let languageString: String
        switch profile {
        case .transcriptEN, .cloudEN, .localENLight, .localENFull:
            languageString = "English"
        default:
            languageString = "Multilingual"
        }

        let modeString: String
        switch intent {
        case .transcribe:
            modeString = "transcription"
        case .notes:
            modeString = "transcription, AI notes"
        case .fullCopilot:
            modeString = "transcription, AI notes, real-time suggestions"
        }

        let providerString: String
        switch profile {
        case .transcriptEN, .transcriptMulti:
            providerString = ""
        case .cloudEN, .cloudMulti:
            providerString = " via cloud"
        case .localENLight, .localENFull, .localMultiLight, .localMultiFull:
            providerString = ", everything local"
        }

        let summary = "\(languageString) \(modeString)\(providerString)"

        var details = ["Transcription: \(transcriptionModel.displayName)"]

        switch profile {
        case .cloudEN, .cloudMulti:
            details.append("LLM: Gemini 3 Flash via OpenRouter")
            if intent == .fullCopilot {
                details.append("Knowledge retrieval: Voyage AI")
            }
        case .localENLight, .localMultiLight:
            details.append("LLM: Phi 3.5 Mini via Ollama")
            if intent == .fullCopilot {
                details.append("Knowledge retrieval: nomic-embed-text via Ollama")
            }
        case .localENFull, .localMultiFull:
            details.append("LLM: Qwen3 8B via Ollama")
            if intent == .fullCopilot {
                details.append("Knowledge retrieval: nomic-embed-text via Ollama")
            }
        case .transcriptEN, .transcriptMulti:
            break
        }

        return DisplayConfig(summary: summary, details: details)
    }

    // MARK: - Skip Logic

    /// Determine whether Screen 2 should be skipped.
    static func nextStepAfterIntent(
        intent: WizardIntent,
        snapshot: SetupSnapshot
    ) -> WizardStep {
        switch intent {
        case .transcribe:
            return snapshot.isEnglishLocale ? .confirmation : .languagePrivacy

        case .notes, .fullCopilot:
            if snapshot.isEnglishLocale && !snapshot.ollamaReachable && !snapshot.hasOpenRouterKey {
                return .languagePrivacy
            }
            if snapshot.isEnglishLocale && snapshot.ollamaReachable && snapshot.hasOpenRouterKey {
                return .languagePrivacy
            }
            if snapshot.isEnglishLocale && !snapshot.ollamaReachable {
                return .providerSetup
            }
            if snapshot.isEnglishLocale && snapshot.ollamaReachable && !snapshot.hasOpenRouterKey {
                return .providerSetup
            }
            return .languagePrivacy
        }
    }

    /// Determine the next step after Screen 2.
    static func nextStepAfterLanguagePrivacy(
        intent: WizardIntent,
        privacy _: WizardPrivacy
    ) -> WizardStep {
        switch intent {
        case .transcribe:
            return .confirmation
        case .notes, .fullCopilot:
            return .providerSetup
        }
    }
}
