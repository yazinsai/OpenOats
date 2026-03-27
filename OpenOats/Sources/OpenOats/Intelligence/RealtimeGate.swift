import Foundation

/// Local heuristic gate that decides whether to surface a suggestion.
/// Replaces the LLM-based surfacing gate for sub-100ms decisions.
struct RealtimeGate: Sendable {
    /// Evaluate whether a suggestion should surface.
    func evaluate(
        text: String,
        speaker: Speaker,
        contextPacks: [KBContextPack],
        kbSimilarityThreshold: Double,
        questionDensity: Double,
        recentSuggestionTexts: [String]
    ) -> GateResult {
        let topScore = contextPacks.first?.score ?? 0

        // KB similarity threshold
        guard topScore >= kbSimilarityThreshold else {
            return GateResult(shouldSurface: false, triggerKind: .general, score: topScore, reason: "KB score below threshold")
        }

        // Detect trigger kind
        let triggerKind = detectTriggerKind(text)

        // Duplicate suppression: Jaccard similarity against recent suggestions
        let candidateText = contextPacks.first?.matchedText ?? ""
        for recent in recentSuggestionTexts.suffix(3) {
            if TextSimilarity.jaccard(candidateText, recent) > 0.7 {
                return GateResult(shouldSurface: false, triggerKind: triggerKind, score: topScore, reason: "Duplicate of recent suggestion")
            }
        }

        // Combined score for burst/decay
        let combinedScore = (questionDensity * 0.4) + (topScore * 0.6)

        return GateResult(
            shouldSurface: true,
            triggerKind: triggerKind,
            score: combinedScore,
            reason: "Passed heuristic gate"
        )
    }

    struct GateResult: Sendable {
        let shouldSurface: Bool
        let triggerKind: RealtimeTriggerKind
        let score: Double
        let reason: String
    }

    // MARK: - Trigger Detection

    private func detectTriggerKind(_ text: String) -> RealtimeTriggerKind {
        let lower = text.lowercased()

        // Question markers
        if lower.contains("?") { return .question }
        let questionStarts = ["what ", "how ", "why ", "should ", "could ", "would ", "do you think", "which "]
        for start in questionStarts {
            if lower.hasPrefix(start) { return .question }
        }

        // Decision markers
        let decisionPhrases = ["should we", "let's go with", "i think we should", "we need to decide", "which one"]
        for phrase in decisionPhrases {
            if lower.contains(phrase) { return .question }
        }

        // Claim markers
        let claimPhrases = ["i think", "i assume", "i believe", "probably", "but ", "however", "i disagree", "that's not", "the problem is"]
        for phrase in claimPhrases {
            if lower.contains(phrase) { return .claim }
        }

        // Topic markers
        let topicPhrases = ["customer", "user", "pain point", "market", "distribution", "pricing", "mvp", "feature", "retention", "churn"]
        for phrase in topicPhrases {
            if lower.contains(phrase) { return .topic }
        }

        return .general
    }

}
