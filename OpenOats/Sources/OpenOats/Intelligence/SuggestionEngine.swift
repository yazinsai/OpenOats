import Foundation
import Observation

/// Generates LLM-powered suggestions based on conversation context and KB results.
///
/// Pipeline: heuristic filter → conversation state update → multi-query KB retrieval → surfacing gate → generation.
@Observable
@MainActor
final class SuggestionEngine {
    @ObservationIgnored nonisolated(unsafe) private var _suggestions: [Suggestion] = []
    private(set) var suggestions: [Suggestion] {
        get { access(keyPath: \.suggestions); return _suggestions }
        set { withMutation(keyPath: \.suggestions) { _suggestions = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    /// The latest suggestion decision, even if it didn't surface (for logging).
    @ObservationIgnored nonisolated(unsafe) private var _lastDecision: SuggestionDecision?
    private(set) var lastDecision: SuggestionDecision? {
        get { access(keyPath: \.lastDecision); return _lastDecision }
        set { withMutation(keyPath: \.lastDecision) { _lastDecision = newValue } }
    }

    private let client = OpenRouterClient()
    private var currentTask: Task<Void, Never>?
    private var lastProcessedUtteranceID: UUID?
    private var lastSuggestionTime: Date?

    // MARK: - Thresholds

    private var cooldownSeconds: TimeInterval { settings.suggestionVerbosity.cooldownSeconds }
    private let minUtteranceWordCount = 8
    private let minUtteranceCharCount = 30
    private let minKBRelevanceScore: Double = 0.35

    // Base gate thresholds, scaled by verbosity
    private static let baseRelevanceScore: Double = 0.72
    private static let baseHelpfulnessScore: Double = 0.75
    private static let baseTimingScore: Double = 0.70
    private static let baseNoveltyScore: Double = 0.65
    private static let baseConfidenceScore: Double = 0.75

    private var minRelevanceScore: Double { Self.baseRelevanceScore * settings.suggestionVerbosity.thresholdMultiplier }
    private var minHelpfulnessScore: Double { Self.baseHelpfulnessScore * settings.suggestionVerbosity.thresholdMultiplier }
    private var minTimingScore: Double { Self.baseTimingScore * settings.suggestionVerbosity.thresholdMultiplier }
    private var minNoveltyScore: Double { Self.baseNoveltyScore * settings.suggestionVerbosity.thresholdMultiplier }
    private var minConfidenceScore: Double { Self.baseConfidenceScore * settings.suggestionVerbosity.thresholdMultiplier }

    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    /// Returns the API key for the current LLM provider (nil for Ollama).
    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .ollama: nil
        case .mlx: nil
        case .openAICompatible: settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    /// Returns the base URL for the current LLM provider (nil uses the default OpenRouter URL).
    /// Throws a fatal error for Ollama if the URL is invalid, preventing silent fallback to OpenRouter.
    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: return nil
        case .ollama:
            let base = settings.ollamaBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/v1/chat/completions") else {
                print("[SuggestionEngine] Invalid Ollama URL: \(settings.ollamaBaseURL)")
                return nil
            }
            return url
        case .mlx:
            let base = settings.mlxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/v1/chat/completions") else {
                print("[SuggestionEngine] Invalid MLX URL: \(settings.mlxBaseURL)")
                return nil
            }
            return url
        case .openAICompatible:
            let base = settings.openAILLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/v1/chat/completions") else {
                print("[SuggestionEngine] Invalid OpenAI Compatible URL: \(settings.openAILLMBaseURL)")
                return nil
            }
            return url
        }
    }

    /// Returns the model identifier for the current LLM provider.
    private var llmModel: String {
        switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
    }

    /// Called when a new THEM utterance is finalized.
    func onThemUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        // Cancel any in-flight request
        currentTask?.cancel()

        // Validate that the current provider has required credentials
        switch settings.llmProvider {
        case .openRouter:
            guard !settings.openRouterApiKey.isEmpty else { return }
        case .ollama:
            guard llmBaseURL != nil else { return }
        case .mlx:
            guard llmBaseURL != nil else { return }
        case .openAICompatible:
            guard llmBaseURL != nil else { return }
        }

        currentTask = Task {
            // Stage 1: Local heuristic pre-filter
            guard shouldEvaluateUtterance(utterance) else { return }

            let trigger = detectTrigger(for: utterance)
            guard trigger != nil else { return }

            isGenerating = true
            defer { isGenerating = false }

            // Stage 2: Update conversation state if needed
            await updateConversationStateIfNeeded(
                latestUtterance: utterance
            )
            guard !Task.isCancelled else { return }

            // Stage 3: Multi-query KB retrieval
            let kbResults = await retrieveEvidence(for: utterance)
            guard !kbResults.isEmpty, !Task.isCancelled else { return }

            let topScore = kbResults.first?.score ?? 0
            guard topScore >= minKBRelevanceScore else { return }

            // Stage 4: Surfacing gate
            let decision = await runSurfacingGate(
                utterance: utterance,
                trigger: trigger!,
                kbResults: kbResults
            )
            lastDecision = decision
            guard !Task.isCancelled else { return }

            guard let decision, decision.shouldSurface,
                  passesThresholds(decision) else { return }

            // Stage 5: Generate suggestion
            let suggestion = await generateSuggestion(
                utterance: utterance,
                decision: decision,
                trigger: trigger!,
                kbResults: kbResults
            )
            guard !Task.isCancelled else { return }

            if let suggestion {
                suggestions.insert(suggestion, at: 0)
                lastSuggestionTime = .now

                // Track shown angle for duplicate suppression
                let angle = String(suggestion.text.prefix(80).lowercased())
                var updatedState = transcriptStore.conversationState
                updatedState.suggestedAnglesRecentlyShown.append(angle)
                // Keep only last 3
                if updatedState.suggestedAnglesRecentlyShown.count > 3 {
                    updatedState.suggestedAnglesRecentlyShown.removeFirst()
                }
                transcriptStore.updateConversationState(updatedState)
            }
        }
    }

    func clear() {
        currentTask?.cancel()
        suggestions.removeAll()
        isGenerating = false
        lastProcessedUtteranceID = nil
        lastSuggestionTime = nil
        lastDecision = nil
    }

    // MARK: - Stage 1: Heuristic Pre-Filter

    private func shouldEvaluateUtterance(_ utterance: Utterance) -> Bool {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Minimum length checks
        let words = text.split(separator: " ")
        guard words.count >= minUtteranceWordCount else { return false }
        guard text.count >= minUtteranceCharCount else { return false }

        // Cooldown
        if let last = lastSuggestionTime,
           Date.now.timeIntervalSince(last) < cooldownSeconds {
            return false
        }

        // Filler detection — skip mostly filler utterances
        let fillerPatterns: Set<String> = [
            "yeah", "yes", "no", "ok", "okay", "right", "sure", "uh", "um",
            "hmm", "huh", "mhm", "like", "so", "well", "anyway", "basically",
            "literally", "actually", "honestly", "totally", "exactly"
        ]
        let lowercaseWords = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let fillerCount = lowercaseWords.filter { fillerPatterns.contains($0) }.count
        let fillerRatio = Double(fillerCount) / Double(words.count)
        if fillerRatio > 0.6 { return false }

        // Near-duplicate check against recent them utterances
        let recentThem = transcriptStore.recentThemUtterances.suffix(3)
        for recent in recentThem {
            if recent.id == utterance.id { continue }
            if TextSimilarity.jaccard(text, recent.text) > 0.8 { return false }
        }

        return true
    }

    // MARK: - Stage 1b: Trigger Detection

    private func detectTrigger(for utterance: Utterance) -> SuggestionTrigger? {
        let text = utterance.text.lowercased()

        // Question detection
        if text.contains("?") || text.hasPrefix("what ") || text.hasPrefix("how ") ||
           text.hasPrefix("why ") || text.hasPrefix("should ") || text.hasPrefix("could ") ||
           text.hasPrefix("would ") || text.hasPrefix("do you think") {
            return SuggestionTrigger(
                kind: .explicitQuestion,
                utteranceID: utterance.id,
                excerpt: String(utterance.text.prefix(100)),
                confidence: 0.8
            )
        }

        // Decision point
        let decisionPhrases = ["should we", "let's go with", "i think we should",
                               "the decision is", "we need to decide", "which one",
                               "option a or", "option b or", "pick between"]
        for phrase in decisionPhrases {
            if text.contains(phrase) {
                return SuggestionTrigger(
                    kind: .decisionPoint,
                    utteranceID: utterance.id,
                    excerpt: String(utterance.text.prefix(100)),
                    confidence: 0.75
                )
            }
        }

        // Disagreement / tension
        let tensionPhrases = ["but ", "however", "i disagree", "that's not",
                              "the problem is", "i'm not sure about", "on the other hand"]
        for phrase in tensionPhrases {
            if text.contains(phrase) {
                return SuggestionTrigger(
                    kind: .disagreement,
                    utteranceID: utterance.id,
                    excerpt: String(utterance.text.prefix(100)),
                    confidence: 0.65
                )
            }
        }

        // Assumption / hypothesis
        let assumptionPhrases = ["i think", "i assume", "i believe", "probably",
                                  "maybe", "what if", "suppose"]
        for phrase in assumptionPhrases {
            if text.contains(phrase) {
                return SuggestionTrigger(
                    kind: .assumption,
                    utteranceID: utterance.id,
                    excerpt: String(utterance.text.prefix(100)),
                    confidence: 0.6
                )
            }
        }

        // Domain-specific signals
        let domainPhrases: [(String, SuggestionTriggerKind)] = [
            ("customer", .customerProblem), ("user", .customerProblem),
            ("pain point", .customerProblem), ("problem", .customerProblem),
            ("market", .distributionGoToMarket), ("distribution", .distributionGoToMarket),
            ("go to market", .distributionGoToMarket), ("pricing", .distributionGoToMarket),
            ("mvp", .productScope), ("wedge", .productScope), ("scope", .productScope),
            ("feature", .productScope), ("prioriti", .prioritization),
            ("retention", .customerProblem), ("churn", .customerProblem),
            ("validation", .customerProblem)
        ]
        for (phrase, kind) in domainPhrases {
            if text.contains(phrase) {
                return SuggestionTrigger(
                    kind: kind,
                    utteranceID: utterance.id,
                    excerpt: String(utterance.text.prefix(100)),
                    confidence: 0.55
                )
            }
        }

        return nil
    }

    // MARK: - Stage 2: Conversation State Update

    private func updateConversationStateIfNeeded(
        latestUtterance: Utterance
    ) async {
        guard transcriptStore.needsStateUpdate else { return }

        let recentUtterances = transcriptStore.recentExchange
        let previousState = transcriptStore.conversationState

        let statePrompt = buildConversationStatePrompt(
            previousState: previousState,
            recentUtterances: recentUtterances,
            latestUtterance: latestUtterance
        )

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: llmModel,
                messages: statePrompt,
                maxTokens: 512,
                baseURL: llmBaseURL
            )

            // Extract JSON from response (handle markdown fences)
            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8) {
                let newState = try JSONDecoder().decode(ConversationStateUpdate.self, from: data)
                // Preserve suggested angles from existing state
                let state = ConversationState(
                    currentTopic: newState.currentTopic,
                    shortSummary: newState.shortSummary,
                    openQuestions: newState.openQuestions,
                    activeTensions: newState.activeTensions,
                    recentDecisions: newState.recentDecisions,
                    themGoals: newState.themGoals,
                    suggestedAnglesRecentlyShown: previousState.suggestedAnglesRecentlyShown,
                    lastUpdatedAt: .now
                )
                transcriptStore.updateConversationState(state)
            }
        } catch {
            print("Conversation state update failed: \(error)")
            // Keep previous state — don't block pipeline
        }
    }

    /// Decodable subset of ConversationState (without app-managed fields)
    private struct ConversationStateUpdate: Codable {
        let currentTopic: String
        let shortSummary: String
        let openQuestions: [String]
        let activeTensions: [String]
        let recentDecisions: [String]
        let themGoals: [String]
    }

    // MARK: - Stage 3: Multi-Query KB Retrieval

    private func retrieveEvidence(for utterance: Utterance) async -> [KBResult] {
        let state = transcriptStore.conversationState
        var queries: [String] = [utterance.text]

        if !state.currentTopic.isEmpty {
            queries.append(state.currentTopic)
        }
        if !state.shortSummary.isEmpty {
            queries.append(state.shortSummary)
        }
        if let topQuestion = state.openQuestions.first {
            queries.append(topQuestion)
        }

        return await knowledgeBase.search(queries: queries, topK: 5)
    }

    // MARK: - Stage 4: Surfacing Gate

    private func runSurfacingGate(
        utterance: Utterance,
        trigger: SuggestionTrigger,
        kbResults: [KBResult]
    ) async -> SuggestionDecision? {
        let messages = buildGatePrompt(
            utterance: utterance,
            trigger: trigger,
            kbResults: kbResults
        )

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: llmModel,
                messages: messages,
                maxTokens: 512,
                baseURL: llmBaseURL
            )

            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8) {
                return try JSONDecoder().decode(SuggestionDecision.self, from: data)
            }
        } catch {
            print("Surfacing gate error: \(error)")
        }
        return nil
    }

    private func passesThresholds(_ decision: SuggestionDecision) -> Bool {
        decision.relevanceScore >= minRelevanceScore &&
        decision.helpfulnessScore >= minHelpfulnessScore &&
        decision.timingScore >= minTimingScore &&
        decision.noveltyScore >= minNoveltyScore &&
        decision.confidence >= minConfidenceScore
    }

    // MARK: - Stage 5: Suggestion Generation

    private func generateSuggestion(
        utterance: Utterance,
        decision: SuggestionDecision,
        trigger: SuggestionTrigger,
        kbResults: [KBResult]
    ) async -> Suggestion? {
        let messages = buildGeneratorPrompt(
            utterance: utterance,
            decision: decision,
            kbResults: Array(kbResults.prefix(3))
        )

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: llmModel,
                messages: messages,
                maxTokens: 300,
                baseURL: llmBaseURL
            )

            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8),
               let output = try? JSONDecoder().decode(GeneratorOutput.self, from: data) {
                let text = "• \(output.headline)\n> \(output.coachingLine)\n> \(output.evidenceLine)"
                return Suggestion(
                    text: text,
                    kbHits: kbResults,
                    decision: decision,
                    trigger: trigger,
                    summarySnapshot: transcriptStore.conversationState.shortSummary
                )
            }

            // Fallback: use raw text if JSON parsing fails
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "—" {
                return Suggestion(
                    text: trimmed,
                    kbHits: kbResults,
                    decision: decision,
                    trigger: trigger,
                    summarySnapshot: transcriptStore.conversationState.shortSummary
                )
            }
        } catch {
            print("Suggestion generation error: \(error)")
        }
        return nil
    }

    private struct GeneratorOutput: Codable {
        let headline: String
        let coachingLine: String
        let evidenceLine: String
    }

    // MARK: - Prompt Builders

    private func buildConversationStatePrompt(
        previousState: ConversationState,
        recentUtterances: [Utterance],
        latestUtterance: Utterance
    ) -> [OpenRouterClient.Message] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let prevJSON = (try? String(data: encoder.encode(previousState), encoding: .utf8)) ?? "{}"

        var conversationText = ""
        for u in recentUtterances {
            let label = u.speaker == .you ? "You" : "Them"
            conversationText += "\(label): \(u.text)\n"
        }

        let system = """
        You are a conversation state tracker for a real-time meeting assistant. \
        Update the meeting state based on new utterances. Output compact JSON only, no prose.

        Rules:
        - 2-4 sentence summary max
        - Prefer unresolved questions over historical detail
        - Prefer what "them" appears to want or optimize for
        - Keep all arrays short (max 3-4 items each)
        - Output only valid JSON matching this schema:
        {"currentTopic":"string","shortSummary":"string","openQuestions":["string"],"activeTensions":["string"],"recentDecisions":["string"],"themGoals":["string"]}
        """

        let user = """
        Previous state:
        \(prevJSON)

        Recent conversation:
        \(conversationText)
        Latest utterance (Them): \(latestUtterance.text)

        Output the updated conversation state as JSON:
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func buildGatePrompt(
        utterance: Utterance,
        trigger: SuggestionTrigger,
        kbResults: [KBResult]
    ) -> [OpenRouterClient.Message] {
        let state = transcriptStore.conversationState
        let recentExchange = transcriptStore.recentExchange

        var conversationText = ""
        for u in recentExchange {
            let label = u.speaker == .you ? "You" : "Them"
            conversationText += "\(label): \(u.text)\n"
        }

        var evidenceText = ""
        for (i, result) in kbResults.prefix(5).enumerated() {
            let header = result.headerContext.isEmpty ? result.sourceFile : "\(result.sourceFile) > \(result.headerContext)"
            evidenceText += "[\(i + 1)] [\(header)] (score: \(String(format: "%.2f", result.score)))\n\(result.text)\n\n"
        }

        let recentAngles = state.suggestedAnglesRecentlyShown.joined(separator: "; ")

        let system = """
        You are a surfacing gate for a real-time meeting copilot. Your job is to decide \
        whether to show a suggestion RIGHT NOW. Optimize aggressively for abstention.

        Rules:
        - Stay silent unless the suggestion would be genuinely useful right now
        - Penalize generic advice
        - Penalize advice already obvious from the conversation
        - Penalize weak or tangential KB matches
        - Penalize interruptions during loose or unfinished ideation
        - Only approve if the user could plausibly use the suggestion in the next one or two turns
        - One strong suggestion is better than four weak ones

        Output only valid JSON matching this schema:
        {"shouldSurface":bool,"confidence":float,"relevanceScore":float,"helpfulnessScore":float,"timingScore":float,"noveltyScore":float,"reason":"string","trigger":{"kind":"string","excerpt":"string","confidence":float}}

        All scores are 0.0-1.0. Set shouldSurface=true ONLY when ALL scores clear threshold.
        """

        let user = """
        Latest utterance (Them): \(utterance.text)

        Recent exchange:
        \(conversationText)
        Conversation state:
        - Topic: \(state.currentTopic)
        - Summary: \(state.shortSummary)
        - Open questions: \(state.openQuestions.joined(separator: ", "))
        - Tensions: \(state.activeTensions.joined(separator: ", "))

        Detected trigger: \(trigger.kind.rawValue) (confidence: \(String(format: "%.2f", trigger.confidence)))
        Trigger excerpt: \(trigger.excerpt)

        KB evidence:
        \(evidenceText)
        Recently shown suggestion angles: \(recentAngles.isEmpty ? "none" : recentAngles)

        Should a suggestion be surfaced now? Output JSON:
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func buildGeneratorPrompt(
        utterance: Utterance,
        decision: SuggestionDecision,
        kbResults: [KBResult]
    ) -> [OpenRouterClient.Message] {
        let state = transcriptStore.conversationState

        var evidenceText = ""
        for result in kbResults {
            let header = result.headerContext.isEmpty ? result.sourceFile : "\(result.sourceFile) > \(result.headerContext)"
            evidenceText += "[\(header)]:\n\(result.text)\n\n"
        }

        let system = """
        You are a real-time meeting copilot generating ONE suggestion for the user. \
        The surfacing gate has already approved this moment. Generate a concise, \
        immediately actionable suggestion.

        Rules:
        - One suggestion only
        - No generic startup advice
        - No multi-bullet lists
        - No filler or hedging
        - Tie the suggestion to a concrete moment in the conversation
        - Ground it in the retrieved KB evidence
        - Prefer a suggested question, reframing, or caution the user can use immediately

        Output only valid JSON:
        {"headline":"string (≤10 words)","coachingLine":"string (one sentence, actionable)","evidenceLine":"string (source reference or key quote)"}
        """

        let user = """
        Latest utterance (Them): \(utterance.text)

        Conversation state:
        - Topic: \(state.currentTopic)
        - Summary: \(state.shortSummary)

        Gate reason: \(decision.reason)

        KB evidence:
        \(evidenceText)
        Generate the suggestion as JSON:
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    // MARK: - Helpers

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences
        if s.hasPrefix("```json") {
            s = String(s.dropFirst(7))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
