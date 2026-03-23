import Foundation
import Observation

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

    @discardableResult
    func append(_ utterance: Utterance) -> Bool {
        guard !shouldSuppressAcousticEcho(utterance) else { return false }
        utterances.append(utterance)
        diagLog("[TRANSCRIPT] appended \(utterance.speaker.storageKey) chars=\(utterance.text.count) total=\(utterances.count)")
        if utterance.speaker.isRemote {
            remoteUtterancesSinceStateUpdate += 1
        }
        return true
    }

    /// Update an existing utterance's refined text by ID, without triggering suggestion regeneration.
    func updateRefinedText(id: UUID, refinedText: String?, status: RefinementStatus) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index] = utterances[index].withRefinement(text: refinedText, status: status)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
        conversationState = .empty
        remoteUtterancesSinceStateUpdate = 0
    }

    func updateConversationState(_ state: ConversationState) {
        conversationState = state
        remoteUtterancesSinceStateUpdate = 0
    }

    /// Whether conversation state needs a refresh (every 2-3 finalized remote utterances)
    var needsStateUpdate: Bool {
        remoteUtterancesSinceStateUpdate >= 2
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

            diagLog(
                "[TRANSCRIPT-ECHO] dropped mic utterance as system-audio echo " +
                "dt=\(String(format: "%.2f", timeDelta)) " +
                "similarity=\(String(format: "%.2f", similarity)) " +
                "you='\(utterance.text.prefix(80))' them='\(candidate.text.prefix(80))'"
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
