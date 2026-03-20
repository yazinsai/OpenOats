import Foundation

enum Speaker: String, Codable, Sendable {
    case you
    case them
}

enum RefinementStatus: String, Codable, Sendable {
    case pending, completed, failed, skipped
}

struct Utterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date
    let refinedText: String?
    let refinementStatus: RefinementStatus?

    init(text: String, speaker: Speaker, timestamp: Date = .now, refinedText: String? = nil, refinementStatus: RefinementStatus? = nil) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.refinedText = refinedText
        self.refinementStatus = refinementStatus
    }

    /// The best available text: refined if available, otherwise raw.
    var displayText: String {
        refinedText ?? text
    }

    func withRefinement(text: String?, status: RefinementStatus) -> Utterance {
        Utterance(
            id: self.id,
            text: self.text,
            speaker: self.speaker,
            timestamp: self.timestamp,
            refinedText: text,
            refinementStatus: status
        )
    }

    /// Private memberwise init that preserves an existing ID.
    private init(id: UUID, text: String, speaker: Speaker, timestamp: Date, refinedText: String?, refinementStatus: RefinementStatus?) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.refinedText = refinedText
        self.refinementStatus = refinementStatus
    }
}

// MARK: - Conversation State

struct ConversationState: Sendable, Codable {
    var currentTopic: String
    var shortSummary: String
    var openQuestions: [String]
    var activeTensions: [String]
    var recentDecisions: [String]
    var themGoals: [String]
    var suggestedAnglesRecentlyShown: [String]
    var lastUpdatedAt: Date

    static let empty = ConversationState(
        currentTopic: "",
        shortSummary: "",
        openQuestions: [],
        activeTensions: [],
        recentDecisions: [],
        themGoals: [],
        suggestedAnglesRecentlyShown: [],
        lastUpdatedAt: .distantPast
    )
}

// MARK: - Suggestion Trigger

enum SuggestionTriggerKind: String, Codable, Sendable {
    case explicitQuestion
    case decisionPoint
    case disagreement
    case assumption
    case prioritization
    case customerProblem
    case distributionGoToMarket
    case productScope
    case unclear
}

struct SuggestionTrigger: Sendable, Codable {
    var kind: SuggestionTriggerKind
    var utteranceID: UUID
    var excerpt: String
    var confidence: Double
}

// MARK: - Suggestion Evidence

struct SuggestionEvidence: Sendable, Codable {
    var sourceFile: String
    var headerContext: String
    var text: String
    var score: Double
}

// MARK: - Suggestion Decision (Surfacing Gate)

struct SuggestionDecision: Sendable, Codable {
    var shouldSurface: Bool
    var confidence: Double
    var relevanceScore: Double
    var helpfulnessScore: Double
    var timingScore: Double
    var noveltyScore: Double
    var reason: String
    var trigger: SuggestionTrigger?
}

// MARK: - Suggestion Feedback

enum SuggestionFeedback: String, Codable, Sendable {
    case helpful
    case notHelpful
    case dismissed
}

// MARK: - KB Result

struct KBResult: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let sourceFile: String
    let headerContext: String
    let score: Double

    init(text: String, sourceFile: String, headerContext: String = "", score: Double) {
        self.id = UUID()
        self.text = text
        self.sourceFile = sourceFile
        self.headerContext = headerContext
        self.score = score
    }
}

// MARK: - Suggestion

struct Suggestion: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let kbHits: [KBResult]
    let decision: SuggestionDecision?
    let trigger: SuggestionTrigger?
    let summarySnapshot: String?
    let feedback: SuggestionFeedback?

    init(
        text: String,
        timestamp: Date = .now,
        kbHits: [KBResult] = [],
        decision: SuggestionDecision? = nil,
        trigger: SuggestionTrigger? = nil,
        summarySnapshot: String? = nil,
        feedback: SuggestionFeedback? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.kbHits = kbHits
        self.decision = decision
        self.trigger = trigger
        self.summarySnapshot = summarySnapshot
        self.feedback = feedback
    }
}

// MARK: - Session Record

/// Codable record for JSONL session persistence
struct SessionRecord: Codable {
    let speaker: Speaker
    let text: String
    let timestamp: Date
    let suggestions: [String]?
    let kbHits: [String]?
    let suggestionDecision: SuggestionDecision?
    let surfacedSuggestionText: String?
    let conversationStateSummary: String?
    let refinedText: String?

    init(
        speaker: Speaker,
        text: String,
        timestamp: Date,
        suggestions: [String]? = nil,
        kbHits: [String]? = nil,
        suggestionDecision: SuggestionDecision? = nil,
        surfacedSuggestionText: String? = nil,
        conversationStateSummary: String? = nil,
        refinedText: String? = nil
    ) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.suggestions = suggestions
        self.kbHits = kbHits
        self.suggestionDecision = suggestionDecision
        self.surfacedSuggestionText = surfacedSuggestionText
        self.conversationStateSummary = conversationStateSummary
        self.refinedText = refinedText
    }

    func withRefinedText(_ text: String?) -> SessionRecord {
        SessionRecord(
            speaker: speaker, text: self.text, timestamp: timestamp,
            suggestions: suggestions, kbHits: kbHits,
            suggestionDecision: suggestionDecision,
            surfacedSuggestionText: surfacedSuggestionText,
            conversationStateSummary: conversationStateSummary,
            refinedText: text
        )
    }
}

// MARK: - Meeting Templates & Enhanced Notes

struct MeetingTemplate: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var systemPrompt: String
    var isBuiltIn: Bool
}

struct TemplateSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let icon: String
    let systemPrompt: String
}

struct EnhancedNotes: Codable, Sendable {
    let template: TemplateSnapshot
    let generatedAt: Date
    let markdown: String
}

struct SessionIndex: Identifiable, Codable, Sendable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var templateSnapshot: TemplateSnapshot?
    var title: String?
    var utteranceCount: Int
    var hasNotes: Bool
    /// The detected meeting application name (e.g. "Zoom", "Microsoft Teams").
    var meetingApp: String?
    /// The ASR engine used for transcription (e.g. "parakeetV2").
    var engine: String?
}

struct SessionSidecar: Codable, Sendable {
    let index: SessionIndex
    var notes: EnhancedNotes?
}
