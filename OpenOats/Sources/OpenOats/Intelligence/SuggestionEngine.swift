import Foundation
import Observation

/// Real-time suggestion engine with 3-layer concurrent architecture.
///
/// Layer 1: Continuous context (pre-fetch KB on partial speech every N seconds)
/// Layer 2: Instant retrieval + local heuristic gate on finalized utterances
/// Layer 3: Streaming LLM synthesis
@Observable
@MainActor
final class SuggestionEngine {
    // MARK: - Observable State

    @ObservationIgnored nonisolated(unsafe) private var _activeSuggestions: [RealtimeSuggestion] = []
    private(set) var activeSuggestions: [RealtimeSuggestion] {
        get { access(keyPath: \.activeSuggestions); return _activeSuggestions }
        set { withMutation(keyPath: \.activeSuggestions) { _activeSuggestions = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isStreaming = false
    private(set) var isStreaming: Bool {
        get { access(keyPath: \.isStreaming); return _isStreaming }
        set { withMutation(keyPath: \.isStreaming) { _isStreaming = newValue } }
    }

    // MARK: - Compatibility Shims

    /// Cached projection keyed by active suggestion IDs to avoid generating new UUIDs on every read.
    @ObservationIgnored nonisolated(unsafe) private var _cachedSuggestions: [Suggestion] = []
    @ObservationIgnored nonisolated(unsafe) private var _cachedSuggestionSourceIDs: [UUID] = []

    /// Compatibility projection for mini bar. Stable IDs: only recomputed when activeSuggestions change.
    var suggestions: [Suggestion] {
        let currentIDs = activeSuggestions.map(\.id)
        if currentIDs == _cachedSuggestionSourceIDs { return _cachedSuggestions }
        _cachedSuggestionSourceIDs = currentIDs
        _cachedSuggestions = activeSuggestions.compactMap { rs in
            guard !rs.displayText.isEmpty else { return nil }
            let kbHits = rs.contextPacks.map { pack in
                KBResult(
                    text: pack.matchedText,
                    sourceFile: pack.relativePath,
                    headerContext: pack.headerBreadcrumb,
                    score: pack.score
                )
            }
            return Suggestion(
                text: rs.displayText,
                kbHits: kbHits
            )
        }
        return _cachedSuggestions
    }

    /// Alias for existing polling code.
    var isGenerating: Bool { isStreaming }

    // MARK: - Dependencies

    private let client = OpenRouterClient()
    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings
    private let preFetchCache: PreFetchCache
    private let gate: RealtimeGate
    private let throttle = BurstDecayThrottle()

    // MARK: - Tasks

    private var preFetchTask: Task<Void, Never>?
    private var backgroundStateTask: Task<Void, Never>?
    private var synthesisTask: Task<Void, Never>?
    private var lastProcessedUtteranceID: UUID?
    private var lastAttemptedPreFetchFingerprint: String?
    private var activeStreamingSuggestionID: UUID?

    /// Text snippets of the last 3 shown suggestions for duplicate suppression.
    private var recentSuggestionTexts: [String] = []

    /// Per-trigger log snapshots for delayed writes (keyed by triggerUtteranceID).
    private var logSnapshots: [UUID: LogSnapshot] = [:]

    private static let maxActiveSuggestions = 3

    struct LogSnapshot {
        let suggestionID: UUID
        let triggerUtteranceID: UUID
        let lifecycle: SuggestionLifecycle
        let surfacedText: String
        let kbHitPaths: [String]
        let createdAt: Date
    }

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
        self.preFetchCache = PreFetchCache(ttlSeconds: 30)
        self.gate = RealtimeGate()
    }

    // MARK: - Layer 1: Continuous Context

    /// Start the periodic pre-fetch loop. Call when a session starts.
    func startPreFetching() {
        preFetchTask?.cancel()
        preFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.settings.preFetchIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self.runPreFetch()
            }
        }
    }

    private func runPreFetch() async {
        let queryText = canonicalCacheQueryText(fallbackText: nil)
        let words = queryText.split(separator: " ")
        guard words.count >= 5 else { return }

        let fingerprint = PreFetchCache.fingerprint(queryText)
        guard fingerprint != lastAttemptedPreFetchFingerprint else { return }
        lastAttemptedPreFetchFingerprint = fingerprint

        if await preFetchCache.get(fingerprint: fingerprint) != nil { return }

        let packs = await knowledgeBase.searchContextPacks(
            queries: [String(words.suffix(40).joined(separator: " "))],
            topK: 3
        )

        guard !packs.isEmpty else { return }
        await preFetchCache.store(fingerprint: fingerprint, packs: packs)

        let topScore = packs.first?.score ?? 0
        if topScore >= settings.kbSimilarityThreshold {
            let querySnippet = String(words.suffix(20).joined(separator: " "))
            tryGateAndSurface(
                text: querySnippet,
                speaker: nil,
                utteranceID: nil,
                triggerFingerprint: fingerprint,
                cachedPacks: packs
            )
        }
    }

    // MARK: - Layer 1b: Background State Tracker

    func triggerBackgroundStateUpdate() {
        guard transcriptStore.needsStateUpdateFromEitherSpeaker else { return }
        guard backgroundStateTask == nil else { return }

        backgroundStateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.backgroundStateTask = nil }
            await self.updateConversationState()
        }
    }

    private func updateConversationState() async {
        let recentUtterances = transcriptStore.recentExchange
        let previousState = transcriptStore.conversationState
        guard let latestUtterance = recentUtterances.last else { return }
        let processedThroughUtteranceID = latestUtterance.id

        let statePrompt = buildConversationStatePrompt(
            previousState: previousState,
            recentUtterances: recentUtterances,
            latestUtterance: latestUtterance
        )

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: activePrimaryModel,
                messages: statePrompt,
                maxTokens: 512,
                baseURL: llmBaseURL(forRealtime: false)
            )

            let jsonString = extractJSON(from: response)
            if let data = jsonString.data(using: .utf8) {
                let update = try JSONDecoder().decode(ConversationStateUpdate.self, from: data)
                let state = ConversationState(
                    currentTopic: update.currentTopic,
                    shortSummary: update.shortSummary,
                    openQuestions: update.openQuestions,
                    activeTensions: update.activeTensions,
                    recentDecisions: update.recentDecisions,
                    themGoals: update.themGoals,
                    suggestedAnglesRecentlyShown: previousState.suggestedAnglesRecentlyShown,
                    lastUpdatedAt: .now
                )
                transcriptStore.updateConversationState(state)
                transcriptStore.markConversationStateUpdated(processedThrough: processedThroughUtteranceID)
            }
        } catch {
            Log.suggestionEngine.error("Background state update failed: \(error, privacy: .public)")
        }
    }

    private struct ConversationStateUpdate: Codable {
        let currentTopic: String
        let shortSummary: String
        let openQuestions: [String]
        let activeTensions: [String]
        let recentDecisions: [String]
        let themGoals: [String]
    }

    // MARK: - Layer 2: Gate + Retrieval

    /// Called when any finalized utterance arrives (from either speaker).
    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        // Validate credentials
        switch settings.llmProvider {
        case .openRouter:
            guard !settings.openRouterApiKey.isEmpty else { return }
        case .ollama, .mlx, .openAICompatible:
            guard llmBaseURL(forRealtime: true) != nil else { return }
        }

        triggerBackgroundStateUpdate()

        let text = utterance.text
        let speaker = utterance.speaker

        let cacheQueryText = canonicalCacheQueryText(fallbackText: text)
        let fingerprint = PreFetchCache.fingerprint(cacheQueryText)

        Task {
            let cachedEntry = await preFetchCache.get(fingerprint: fingerprint)
            let packs: [KBContextPack]

            if let cached = cachedEntry {
                packs = cached.packs
            } else {
                packs = await knowledgeBase.searchContextPacks(
                    queries: [text],
                    topK: 3
                )
            }

            tryGateAndSurface(
                text: text,
                speaker: speaker,
                utteranceID: utterance.id,
                triggerFingerprint: fingerprint,
                cachedPacks: packs
            )
        }
    }

    private func tryGateAndSurface(
        text: String,
        speaker: Speaker?,
        utteranceID: UUID?,
        triggerFingerprint: String?,
        cachedPacks: [KBContextPack]
    ) {
        let gateResult = gate.evaluate(
            text: text,
            speaker: speaker ?? .them,
            contextPacks: cachedPacks,
            kbSimilarityThreshold: settings.kbSimilarityThreshold,
            questionDensity: transcriptStore.questionDensity,
            recentSuggestionTexts: recentSuggestionTexts
        )

        guard gateResult.shouldSurface else { return }

        let candidate = RealtimeSuggestionCandidate(
            triggerKind: gateResult.triggerKind,
            triggerExcerpt: String(text.prefix(100)),
            triggerUtteranceID: utteranceID,
            triggerFingerprint: triggerFingerprint,
            contextPacks: cachedPacks,
            score: gateResult.score
        )

        let kbRelevance = cachedPacks.first?.score ?? 0
        let throttleDecision = throttle.evaluate(
            candidateScore: candidate.score,
            questionDensity: transcriptStore.questionDensity,
            kbRelevance: kbRelevance
        )

        guard throttleDecision.shouldShow else { return }
        guard !candidate.isStale else { return }

        surfaceCandidate(candidate)
    }

    // MARK: - Layer 3: Streaming Synthesis

    private func surfaceCandidate(_ candidate: RealtimeSuggestionCandidate) {
        if let currentIdx = activeSuggestions.firstIndex(where: { $0.lifecycle == .streaming }) {
            activeSuggestions[currentIdx].lifecycle = .superseded
        }
        synthesisTask?.cancel()

        let suggestion = RealtimeSuggestion(
            triggerKind: candidate.triggerKind,
            triggerExcerpt: candidate.triggerExcerpt,
            triggerUtteranceID: candidate.triggerUtteranceID,
            contextPacks: candidate.contextPacks,
            candidateScore: candidate.score
        )

        activeSuggestions.insert(suggestion, at: 0)
        if activeSuggestions.count > Self.maxActiveSuggestions {
            activeSuggestions = Array(activeSuggestions.prefix(Self.maxActiveSuggestions))
        }

        let snippetText = suggestion.rawSnippet
        recentSuggestionTexts.append(snippetText)
        if recentSuggestionTexts.count > 3 {
            recentSuggestionTexts.removeFirst()
        }

        throttle.recordSurfaced(score: candidate.score)

        // Store log snapshot for delayed writes
        if let triggerID = candidate.triggerUtteranceID {
            logSnapshots[triggerID] = LogSnapshot(
                suggestionID: suggestion.id,
                triggerUtteranceID: triggerID,
                lifecycle: .raw,
                surfacedText: suggestion.rawSnippet,
                kbHitPaths: candidate.contextPacks.map(\.relativePath),
                createdAt: .now
            )
            if logSnapshots.count > 10 {
                let oldest = logSnapshots.sorted { $0.value.createdAt < $1.value.createdAt }
                for entry in oldest.prefix(logSnapshots.count - 10) {
                    logSnapshots.removeValue(forKey: entry.key)
                }
            }
        }

        let suggestionID = suggestion.id
        activeStreamingSuggestionID = suggestionID
        isStreaming = true

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            await self.streamSynthesis(
                suggestionID: suggestionID,
                triggerKind: candidate.triggerKind,
                triggerExcerpt: candidate.triggerExcerpt,
                contextPacks: candidate.contextPacks,
                triggerUtteranceID: candidate.triggerUtteranceID
            )
            if self.activeStreamingSuggestionID == suggestionID {
                self.activeStreamingSuggestionID = nil
                self.isStreaming = false
            }
        }
    }

    private func streamSynthesis(
        suggestionID: UUID,
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        contextPacks: [KBContextPack],
        triggerUtteranceID: UUID?
    ) async {
        guard let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        activeSuggestions[idx].lifecycle = .streaming

        let messages = buildSynthesisPrompt(
            triggerKind: triggerKind,
            triggerExcerpt: triggerExcerpt,
            contextPacks: contextPacks
        )

        do {
            let stream = await client.streamCompletion(
                apiKey: llmApiKey,
                model: settings.activeRealtimeModel,
                messages: messages,
                maxTokens: 200,
                baseURL: llmBaseURL(forRealtime: true)
            )

            var accumulated = ""
            for try await chunk in stream {
                guard !Task.isCancelled else { break }
                accumulated += chunk
                if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                    activeSuggestions[idx].synthesizedText = accumulated
                }
            }

            if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }) {
                if Task.isCancelled {
                    markSuperseded(suggestionID)
                } else {
                    activeSuggestions[idx].lifecycle = .completed
                    // Update log snapshot with final text
                    if let triggerID = triggerUtteranceID {
                        logSnapshots[triggerID] = LogSnapshot(
                            suggestionID: suggestionID,
                            triggerUtteranceID: triggerID,
                            lifecycle: .completed,
                            surfacedText: accumulated,
                            kbHitPaths: contextPacks.map(\.relativePath),
                            createdAt: .now
                        )
                    }
                }
            }
        } catch is CancellationError {
            markSuperseded(suggestionID)
        } catch {
            Log.suggestionEngine.error("Synthesis stream error: \(error, privacy: .public)")
            if !Task.isCancelled {
                if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }),
                   activeSuggestions[idx].lifecycle != .superseded {
                    activeSuggestions[idx].lifecycle = .failed
                    updateLogSnapshotLifecycle(suggestionID: suggestionID, triggerUtteranceID: triggerUtteranceID, lifecycle: .failed)
                }
            }
        }
    }

    private func markSuperseded(_ suggestionID: UUID) {
        if let idx = activeSuggestions.firstIndex(where: { $0.id == suggestionID }),
           activeSuggestions[idx].lifecycle != .superseded {
            activeSuggestions[idx].lifecycle = .superseded
            updateLogSnapshotLifecycle(suggestionID: suggestionID, triggerUtteranceID: activeSuggestions[idx].triggerUtteranceID, lifecycle: .superseded)
        }
    }

    /// Update the log snapshot lifecycle for a suggestion, preserving the surfaced text.
    private func updateLogSnapshotLifecycle(suggestionID: UUID, triggerUtteranceID: UUID?, lifecycle: SuggestionLifecycle) {
        guard let triggerID = triggerUtteranceID,
              var existing = logSnapshots[triggerID],
              existing.suggestionID == suggestionID else { return }
        logSnapshots[triggerID] = LogSnapshot(
            suggestionID: existing.suggestionID,
            triggerUtteranceID: existing.triggerUtteranceID,
            lifecycle: lifecycle,
            surfacedText: existing.surfacedText,
            kbHitPaths: existing.kbHitPaths,
            createdAt: existing.createdAt
        )
    }

    // MARK: - Log Snapshot API

    /// Retrieve the log snapshot for a specific trigger utterance ID.
    func logSnapshot(forTriggerUtteranceID id: UUID) -> LogSnapshot? {
        logSnapshots[id]
    }

    // MARK: - Lifecycle

    func clear() {
        preFetchTask?.cancel()
        backgroundStateTask?.cancel()
        synthesisTask?.cancel()
        preFetchTask = nil
        backgroundStateTask = nil
        synthesisTask = nil
        activeSuggestions.removeAll()
        isStreaming = false
        activeStreamingSuggestionID = nil
        lastProcessedUtteranceID = nil
        lastAttemptedPreFetchFingerprint = nil
        recentSuggestionTexts.removeAll()
        logSnapshots.removeAll()
        throttle.clear()
        Task { await preFetchCache.clear() }
    }

    func stopPreFetching() {
        preFetchTask?.cancel()
        preFetchTask = nil
    }

    private func canonicalCacheQueryText(fallbackText: String?) -> String {
        let rolling = transcriptStore.preFetchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rolling.isEmpty { return rolling }
        return fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - LLM Helpers

    private var activePrimaryModel: String {
        switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .ollama: nil
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    private func llmBaseURL(forRealtime: Bool) -> URL? {
        switch settings.llmProvider {
        case .openRouter: return nil
        case .ollama:
            return OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .mlx:
            return OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            return OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }

    // MARK: - Prompts

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
            let label = u.speaker.displayLabel
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
        Latest utterance (\(latestUtterance.speaker.displayLabel)): \(latestUtterance.text)

        Output the updated conversation state as JSON:
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func buildSynthesisPrompt(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        contextPacks: [KBContextPack]
    ) -> [OpenRouterClient.Message] {
        let state = transcriptStore.conversationState

        if contextPacks.isEmpty {
            return buildTranscriptOnlyPrompt(triggerKind: triggerKind, triggerExcerpt: triggerExcerpt, state: state)
        }

        var evidenceText = ""
        for pack in contextPacks.prefix(3) {
            evidenceText += "[\(pack.displayBreadcrumb)]:\n\(pack.matchedText)\n"
            if let prev = pack.previousSiblingText {
                evidenceText += "(preceding context: \(prev.prefix(200)))\n"
            }
            evidenceText += "\n"
        }

        let formatInstruction: String
        switch triggerKind {
        case .question:
            formatInstruction = "Suggest a specific answer or data point the user can reference."
        case .claim:
            formatInstruction = "Surface supporting or contradicting evidence from the KB."
        case .topic:
            formatInstruction = "Surface the most relevant related context from the KB."
        case .general:
            formatInstruction = "Briefly explain why this KB context is relevant right now."
        }

        let system = """
        You are a real-time meeting copilot whispering key facts to the listener.

        Format rules:
        - Lead with a **bold** one-line takeaway
        - Follow with 2-4 short bullet points containing specific names, numbers, or quotes extracted directly from the evidence
        - Each bullet should be one line — scannable at a glance
        - Always include specific company names, dollar amounts, and metrics from the evidence — never paraphrase into vague summaries
        - No filler, no hedging, no preamble, no "why this is relevant" explanations
        - Use **bold** for company names, dollar amounts, and key metrics

        \(formatInstruction)
        """

        let user = """
        Trigger: \(triggerExcerpt)

        Conversation context: \(state.shortSummary.isEmpty ? "N/A" : state.shortSummary)

        Evidence:
        \(evidenceText)
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func buildTranscriptOnlyPrompt(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        state: ConversationState
    ) -> [OpenRouterClient.Message] {
        let formatInstruction: String
        switch triggerKind {
        case .question:
            formatInstruction = "Suggest a concrete way to answer this question or a follow-up question that would clarify the discussion."
        case .claim:
            formatInstruction = "Identify the key assumption behind this claim and suggest a question or angle to probe it."
        case .topic, .general:
            formatInstruction = "Surface a relevant insight or suggest a useful follow-up based on what has been discussed."
        }

        var contextLines: [String] = []
        if !state.currentTopic.isEmpty { contextLines.append("Topic: \(state.currentTopic)") }
        if !state.shortSummary.isEmpty { contextLines.append("Summary: \(state.shortSummary)") }
        if !state.openQuestions.isEmpty { contextLines.append("Open questions: \(state.openQuestions.joined(separator: "; "))") }
        if !state.activeTensions.isEmpty { contextLines.append("Tensions: \(state.activeTensions.joined(separator: "; "))") }
        if !state.recentDecisions.isEmpty { contextLines.append("Decisions: \(state.recentDecisions.joined(separator: "; "))") }

        let system = """
        You are a real-time meeting copilot whispering useful insights to the listener.

        Format rules:
        - Lead with a **bold** one-line insight or suggested question
        - Follow with 1-2 short bullet points with specific, actionable detail
        - Each bullet should be one line — scannable at a glance
        - No filler, no hedging, no preamble
        - Be concise — the listener is in a live conversation

        \(formatInstruction)
        """

        let user = """
        Trigger: \(triggerExcerpt)

        Conversation context:
        \(contextLines.isEmpty ? "N/A" : contextLines.joined(separator: "\n"))
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user)
        ]
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
