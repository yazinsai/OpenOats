import Foundation
import Observation
import os

@Observable
@MainActor
final class TranscriptStore {
    private let acousticEchoWindow: TimeInterval = 1.75
    private let acousticEchoSimilarityThreshold = 0.78
    private let acousticEchoMinimumWordCount = 4
    private let acousticEchoMinimumCharacterCount = 20

    @ObservationIgnored nonisolated(unsafe) private var _utterances: [Utterance] = []
    private(set) var utterances: [Utterance] {
        get { access(keyPath: \.utterances); return _utterances }
        set { withMutation(keyPath: \.utterances) { _utterances = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _conversationState: ConversationState = .empty
    private(set) var conversationState: ConversationState {
        get { access(keyPath: \.conversationState); return _conversationState }
        set { withMutation(keyPath: \.conversationState) { _conversationState = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _volatileYouText = ""
    var volatileYouText: String {
        get { access(keyPath: \.volatileYouText); return _volatileYouText }
        set { withMutation(keyPath: \.volatileYouText) { _volatileYouText = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _volatileThemText = ""
    var volatileThemText: String {
        get { access(keyPath: \.volatileThemText); return _volatileThemText }
        set { withMutation(keyPath: \.volatileThemText) { _volatileThemText = newValue } }
    }

    /// Count of finalized remote utterances since last state update
    private var remoteUtterancesSinceStateUpdate: Int = 0

    /// Count of finalized utterances from either speaker since last state update
    private var utterancesSinceStateUpdate: Int = 0

    /// Rolling timestamps of all utterances in the last 60 seconds (for density calculation)
    private var recentUtteranceTimestamps: [Date] = []
    /// Rolling timestamps of question-bearing utterances in the last 60 seconds
    private var recentQuestionTimestamps: [Date] = []

    /// Ratio of question-bearing utterances in the rolling 60-second window.
    var questionDensity: Double {
        pruneTimestamps()
        guard !recentUtteranceTimestamps.isEmpty else { return 0 }
        return Double(recentQuestionTimestamps.count) / Double(recentUtteranceTimestamps.count)
    }

    /// Whether conversation state needs a refresh (every 2-3 finalized remote utterances)
    var needsStateUpdate: Bool {
        remoteUtterancesSinceStateUpdate >= 2
    }

    /// Whether conversation state needs a refresh from either speaker (every 2-3 utterances)
    var needsStateUpdateFromEitherSpeaker: Bool {
        utterancesSinceStateUpdate >= 2
    }

    @discardableResult
    func append(_ utterance: Utterance) -> Bool {
        guard !shouldSuppressAcousticEcho(utterance) else { return false }
        utterances.append(utterance)

        pruneTimestamps()
        recentUtteranceTimestamps.append(utterance.timestamp)
        if isQuestion(utterance.text) {
            recentQuestionTimestamps.append(utterance.timestamp)
        }

        if utterance.speaker.isRemote {
            remoteUtterancesSinceStateUpdate += 1
        }
        utterancesSinceStateUpdate += 1
        return true
    }

    /// Update an existing utterance's cleaned text by ID, without triggering suggestion regeneration.
    func updateCleanedText(id: UUID, cleanedText: String?, status: TextCleanupStatus) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index] = utterances[index].withCleanup(text: cleanedText, status: status)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
        conversationState = .empty
        remoteUtterancesSinceStateUpdate = 0
        utterancesSinceStateUpdate = 0
        recentUtteranceTimestamps.removeAll()
        recentQuestionTimestamps.removeAll()
    }

    func updateConversationState(_ state: ConversationState) {
        conversationState = state
        // Reset remote counter for backwards compatibility with legacy engine (needsStateUpdate)
        remoteUtterancesSinceStateUpdate = 0
        // Don't reset utterancesSinceStateUpdate — markConversationStateUpdated handles that
        // Don't reset question-density timestamps — they track rolling density independent of state updates
    }

    /// Mark state as updated through a specific utterance snapshot.
    func markConversationStateUpdated(processedThrough utteranceID: UUID) {
        // Find how many utterances arrived after the one we processed through
        if let idx = utterances.lastIndex(where: { $0.id == utteranceID }) {
            let arrivedAfter = utterances.count - 1 - idx
            utterancesSinceStateUpdate = arrivedAfter
            // Keep remote counter in sync
            remoteUtterancesSinceStateUpdate = utterances.suffix(arrivedAfter).filter { $0.speaker.isRemote }.count
        } else {
            utterancesSinceStateUpdate = 0
            remoteUtterancesSinceStateUpdate = 0
        }
    }

    var lastRemoteUtterance: Utterance? {
        utterances.last(where: { $0.speaker.isRemote })
    }

    /// Last N utterances for prompt context
    var recentUtterances: [Utterance] {
        Array(utterances.suffix(10))
    }

    /// Recent 6 utterances for gate/generation prompts
    var recentExchange: [Utterance] {
        Array(utterances.suffix(6))
    }

    /// Recent remote-only utterances for trigger analysis
    var recentRemoteUtterances: [Utterance] {
        utterances.suffix(10).filter { $0.speaker.isRemote }
    }

    /// Combined partial text from both speakers (for pre-fetch display).
    var combinedPartialText: String {
        var parts: [String] = []
        if !volatileThemText.isEmpty { parts.append("Them: \(volatileThemText)") }
        if !volatileYouText.isEmpty { parts.append("You: \(volatileYouText)") }
        return parts.joined(separator: "\n")
    }

    /// Recent finalized text window (last ~500 chars) for pre-fetch queries.
    var recentTextWindow: String {
        var result = ""
        for u in utterances.reversed() {
            let label = u.speaker.isRemote ? u.speaker.displayLabel : "You"
            let line = "\(label): \(u.text)"
            if result.count + line.count > 500 { break }
            result = line + "\n" + result
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best available text for pre-fetch queries: partial if available, else recent finalized.
    var preFetchQueryText: String {
        let partial = combinedPartialText
        return partial.isEmpty ? recentTextWindow : partial
    }

    // MARK: - Private Helpers

    private static let questionLeadingKeywords: Set<String> = [
        "what", "how", "why", "should", "could", "would", "which",
        "do", "does", "did", "is", "are", "was", "were", "can", "will"
    ]

    private func pruneTimestamps() {
        let cutoff = Date.now.addingTimeInterval(-60)
        recentUtteranceTimestamps.removeAll { $0 < cutoff }
        recentQuestionTimestamps.removeAll { $0 < cutoff }
    }

    private func isQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let firstWord = text.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return Self.questionLeadingKeywords.contains(firstWord)
    }

    private func shouldSuppressAcousticEcho(_ utterance: Utterance) -> Bool {
        guard utterance.speaker == .you else { return false }

        let normalizedYouText = TextSimilarity.normalizedText(utterance.text)
        guard isEligibleForEchoCheck(normalizedYouText) else { return false }

        for candidate in utterances.reversed() where candidate.speaker.isRemote {
            let timeDelta = utterance.timestamp.timeIntervalSince(candidate.timestamp)
            guard timeDelta >= 0 else { continue }
            guard timeDelta <= acousticEchoWindow else { break }

            let normalizedThemText = TextSimilarity.normalizedText(candidate.text)
            guard isEligibleForEchoCheck(normalizedThemText) else { continue }

            let similarity = TextSimilarity.jaccard(normalizedYouText, normalizedThemText)
            let containsOther =
                normalizedYouText.contains(normalizedThemText) ||
                normalizedThemText.contains(normalizedYouText)

            guard similarity >= acousticEchoSimilarityThreshold || containsOther else { continue }

            let dtFormatted = String(format: "%.2f", timeDelta)
            let simFormatted = String(format: "%.2f", similarity)
            let youSnippet = String(utterance.text.prefix(80))
            let themSnippet = String(candidate.text.prefix(80))
            Log.transcript.info(
                "Dropped mic utterance as system-audio echo dt=\(dtFormatted, privacy: .public) similarity=\(simFormatted, privacy: .public) you='\(youSnippet, privacy: .private)' them='\(themSnippet, privacy: .private)'"
            )
            return true
        }

        return false
    }

    private func isEligibleForEchoCheck(_ normalizedText: String) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= acousticEchoMinimumWordCount ||
            normalizedText.count >= acousticEchoMinimumCharacterCount
    }
}
