import Foundation
import Observation

@Observable
@MainActor
final class SidecastEngine {
    @ObservationIgnored nonisolated(unsafe) private var _messages: [SidecastMessage] = []
    private(set) var messages: [SidecastMessage] {
        get { access(keyPath: \.messages); return _messages }
        set { withMutation(keyPath: \.messages) { _messages = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    var suggestions: [Suggestion] {
        messages
            .sorted { $0.timestamp > $1.timestamp }
            .map { Suggestion(text: "\($0.personaName): \($0.text)") }
    }

    private let client = OpenRouterClient()
    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings

    private var generationTask: Task<Void, Never>?
    private var lastProcessedUtteranceID: UUID?
    private var lastGenerationStartedAt: Date = .distantPast
    private var recentBubbleTexts: [String] = []
    private var lastSpokenAtByPersona: [UUID: Date] = [:]

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        guard settings.sidebarMode == .sidecast else { return }
        let personas = settings.enabledSidecastPersonas
        guard !personas.isEmpty else { return }
        guard canCallLLM else { return }

        let now = Date.now
        guard now.timeIntervalSince(lastGenerationStartedAt) >= settings.sidecastIntensity.generationCooldownSeconds else {
            return
        }
        lastGenerationStartedAt = now

        generationTask?.cancel()
        isGenerating = true

        let recentExchange = transcriptStore.recentExchange
        let recentUtterances = transcriptStore.recentUtterances
        let conversationState = transcriptStore.conversationState
        let recentTexts = recentBubbleTexts
        let lastSpoken = lastSpokenAtByPersona

        generationTask = Task { [weak self] in
            guard let self else { return }

            let evidence = await self.loadEvidence(for: utterance.text)
            let prompt = self.buildPrompt(
                utterance: utterance,
                recentExchange: recentExchange,
                recentUtterances: recentUtterances,
                state: conversationState,
                personas: personas,
                evidence: evidence
            )

            do {
                let useWebSearch = self.shouldUseWebSearch(for: personas)
                let response = try await self.client.complete(
                    apiKey: self.llmApiKey,
                    model: self.settings.activeRealtimeModel,
                    messages: prompt,
                    maxTokens: self.settings.sidecastMaxTokens,
                    temperature: self.settings.sidecastTemperature,
                    baseURL: self.llmBaseURL,
                    webSearch: useWebSearch
                )
                let decoded = try self.decodeResponse(response)

                await MainActor.run {
                    self.apply(
                        decoded,
                        personas: personas,
                        evidence: evidence,
                        utterance: utterance,
                        recentTexts: recentTexts,
                        lastSpokenAtByPersona: lastSpoken
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isGenerating = false
                }
            } catch {
                Log.sidecast.error("Generation failed: \(error, privacy: .public)")
                await MainActor.run {
                    self.isGenerating = false
                }
            }
        }
    }

    func message(for personaID: UUID) -> SidecastMessage? {
        messages.first(where: { $0.personaID == personaID })
    }

    func clear() {
        generationTask?.cancel()
        generationTask = nil
        messages.removeAll()
        isGenerating = false
        lastProcessedUtteranceID = nil
        lastGenerationStartedAt = .distantPast
        recentBubbleTexts.removeAll()
        lastSpokenAtByPersona.removeAll()
    }

    private func apply(
        _ response: SidecastResponse,
        personas: [SidecastPersona],
        evidence: [KBContextPack],
        utterance: Utterance,
        recentTexts: [String],
        lastSpokenAtByPersona: [UUID: Date]
    ) {
        defer { isGenerating = false }

        let personaByID = Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) })
        let topBreadcrumb = evidence.first?.displayBreadcrumb ?? ""
        let now = utterance.timestamp

        let ranked = response.messages
            .filter { $0.speak }
            .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }

        var accepted: [SidecastMessage] = []
        var dedupeCorpus = recentTexts

        for candidate in ranked {
            guard accepted.count < settings.sidecastIntensity.maxMessagesPerTurn else { break }
            guard let persona = personaByID[candidate.personaID] else { continue }

            if !settings.sidecastIntensity.skipPersonaCooldowns,
               let lastSpoken = lastSpokenAtByPersona[persona.id],
               now.timeIntervalSince(lastSpoken) < persona.cadence.cooldownSeconds {
                continue
            }

            let cleanedText = sanitize(candidate.text, limit: persona.verbosity.characterLimit)
            guard !cleanedText.isEmpty else { continue }

            if dedupeCorpus.contains(where: { TextSimilarity.jaccard($0, cleanedText) > 0.62 }) {
                continue
            }

            let value = max(0, min(1, candidate.value ?? 0.5))
            if value < settings.sidecastMinValueThreshold { continue }

            let evidenceRequired = persona.evidencePolicy == .required
            if evidenceRequired && !persona.webSearchEnabled && evidence.isEmpty {
                continue
            }

            let confidence = max(0, min(1, candidate.confidence ?? 0.55))
            if evidenceRequired && !persona.webSearchEnabled && confidence < 0.35 {
                continue
            }

            let message = SidecastMessage(
                personaID: persona.id,
                personaName: persona.name,
                text: cleanedText,
                timestamp: now,
                confidence: confidence,
                priority: candidate.priority ?? 0.5,
                value: value,
                sourceBreadcrumb: topBreadcrumb
            )

            accepted.append(message)
            dedupeCorpus.append(cleanedText)
        }

        guard !accepted.isEmpty else { return }

        var updated = Dictionary(uniqueKeysWithValues: messages.map { ($0.personaID, $0) })
        for message in accepted {
            updated[message.personaID] = message
            self.lastSpokenAtByPersona[message.personaID] = message.timestamp
            recentBubbleTexts.append(message.text)
        }
        if recentBubbleTexts.count > 12 {
            recentBubbleTexts.removeFirst(recentBubbleTexts.count - 12)
        }

        messages = updated.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.personaName < rhs.personaName
        }
    }

    private static let sanitizePatterns: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]+\)"#, "$1"),                             // [text](url) → text
            (#"https?://\S+"#, ""),                                         // bare URLs
            (#"\b\w+\.(com|org|net|io|ai|app|dev|co|edu|gov)\b"#, ""),     // bare domains
            (#"\([^)]*\b(source|via|per|from|according)\b[^)]*\)"#, ""),   // (source: …) parentheticals
            (#"\[\s*\]"#, ""),                                              // leftover empty []
        ]
        return patterns.compactMap { (pattern, template) in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, template) }
        }
    }()

    private func sanitize(_ text: String, limit: Int) -> String {
        var result = text
        for (regex, template) in Self.sanitizePatterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        let collapsed = result
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadEvidence(for text: String) async -> [KBContextPack] {
        guard settings.kbFolderURL != nil else { return [] }
        return await knowledgeBase.searchContextPacks(queries: [text], topK: 3)
    }

    private func buildPrompt(
        utterance: Utterance,
        recentExchange: [Utterance],
        recentUtterances: [Utterance],
        state: ConversationState,
        personas: [SidecastPersona],
        evidence: [KBContextPack]
    ) -> [OpenRouterClient.Message] {
        let personaText = personas.map { persona in
            """
            - id: \(persona.id.uuidString)
              name: \(persona.name)
              subtitle: \(persona.subtitle)
              prompt: \(persona.prompt)
              verbosity: \(persona.verbosity.displayName) (max \(persona.verbosity.characterLimit) chars)
              cadence: \(persona.cadence.displayName)
              evidence: \(persona.evidencePolicy.displayName)
            """
        }.joined(separator: "\n")

        let transcriptText = recentExchange
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let widerContext = recentUtterances
            .map { "\($0.speaker.displayLabel): \($0.text)" }
            .joined(separator: "\n")

        let evidenceText: String
        if evidence.isEmpty {
            evidenceText = "No KB evidence retrieved for this turn."
        } else {
            evidenceText = evidence.enumerated().map { index, pack in
                """
                [\(index + 1)] \(pack.displayBreadcrumb) (score \(String(format: "%.2f", pack.score)))
                \(pack.matchedText)
                """
            }.joined(separator: "\n\n")
        }

        let stateSummary = state.shortSummary.isEmpty ? "No structured state yet." : state.shortSummary
        let openQuestions = state.openQuestions.isEmpty ? "None" : state.openQuestions.joined(separator: "; ")

        let systemTemplate = settings.sidecastSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system: String
        if systemTemplate.isEmpty {
            system = """
            You are Sidecast, a live multi-persona producer for a host-assist sidebar.
            Decide which personas should speak right now in response to the latest utterance.

            Quality bar:
            - Only speak when you have genuine insight — a non-obvious fact, a sharp reframe, a useful correction, or a punchy callback.
            - Silence is better than filler. If nothing clears the bar, return {"messages":[]}.
            - Every bubble should make the host think "glad I saw that." If it wouldn't, don't send it.

            Rules:
            - Return valid JSON only.
            - Use at most \(settings.sidecastIntensity.maxMessagesPerTurn) persona messages.
            - Never include URLs, links, citations, or source references in the text. The text is the insight itself, nothing else.
            - No markdown, no emoji, no stage directions, no quotes around the text.
            - Keep text extremely dense — every word must earn its place.
            - Fact-heavy personas must lead with specific numbers, percentages, dates, or named sources. Never say "X is higher" — say "X is 42% higher." Avoid vague qualifiers like "significantly", "increasingly", "many" — replace them with the actual number. If no precise data is available, stay silent rather than generalizing.
            - Humor and chaos personas can be sharp, but never hateful or unusably toxic.
            - Set priority (0.0–1.0) honestly: 0.9+ means "the host needs to see this right now." Most messages should be 0.4–0.7.
            - Set confidence (0.0–1.0) based on how sure you are the claim is correct. Below 0.5 means you're guessing.
            - Set value (0.0–1.0): how much this message would genuinely help the host. Be brutally honest.
              0.0–0.3: generic, obvious, or hollow — anyone could say this. Do not send.
              0.4–0.5: mildly interesting but not actionable.
              0.6–0.7: solid insight the host probably didn't know or hadn't considered.
              0.8–1.0: genuinely surprising, corrects a misconception, or provides a killer reframe.

            Output schema:
            {"messages":[{"persona_id":"UUID","speak":true,"text":"string","priority":0.0,"confidence":0.0,"value":0.0}]}
            """
        } else {
            system = systemTemplate
                .replacingOccurrences(of: "{{maxMessagesPerTurn}}", with: "\(settings.sidecastIntensity.maxMessagesPerTurn)")
        }

        let user = """
        Latest utterance:
        \(utterance.speaker.displayLabel): \(utterance.text)

        Recent exchange:
        \(transcriptText)

        Wider context:
        \(widerContext)

        Conversation summary:
        \(stateSummary)

        Open questions:
        \(openQuestions)

        Personas:
        \(personaText)

        Evidence:
        \(evidenceText)
        """

        return [
            .init(role: "system", content: system),
            .init(role: "user", content: user),
        ]
    }

    private func decodeResponse(_ response: String) throws -> SidecastResponse {
        let json = extractJSON(from: response)
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8 response"))
        }
        return try JSONDecoder().decode(SidecastResponse.self, from: data)
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCallLLM: Bool {
        switch settings.llmProvider {
        case .openRouter:
            return !settings.openRouterApiKey.isEmpty
        case .ollama, .mlx, .openAICompatible:
            return llmBaseURL != nil
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

    /// Web search is enabled when the provider is OpenRouter and any enabled persona has it on.
    private func shouldUseWebSearch(for personas: [SidecastPersona]) -> Bool {
        settings.llmProvider == .openRouter && personas.contains(where: { $0.webSearchEnabled })
    }

    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: nil
        case .ollama:
            OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .mlx:
            OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }
}

private struct SidecastResponse: Codable {
    let messages: [SidecastResponseMessage]
}

private struct SidecastResponseMessage: Codable {
    let personaID: UUID
    let speak: Bool
    let text: String
    let priority: Double?
    let confidence: Double?
    let value: Double?

    enum CodingKeys: String, CodingKey {
        case personaID = "persona_id"
        case speak
        case text
        case priority
        case confidence
        case value
    }
}
