import Foundation

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

/// Collapsed trigger categories for the real-time pipeline.
enum RealtimeTriggerKind: String, Codable, Sendable {
    case question   // maps from: explicitQuestion, decisionPoint
    case claim      // maps from: assumption, disagreement
    case topic      // maps from: customerProblem, distributionGoToMarket, productScope, prioritization
    case general    // fallback

    init(from legacy: SuggestionTriggerKind) {
        switch legacy {
        case .explicitQuestion, .decisionPoint: self = .question
        case .assumption, .disagreement: self = .claim
        case .customerProblem, .distributionGoToMarket, .productScope, .prioritization: self = .topic
        case .unclear: self = .general
        }
    }
}

struct SuggestionTrigger: Sendable, Codable, Equatable {
    var kind: SuggestionTriggerKind
    var utteranceID: UUID
    var excerpt: String
    var confidence: Double
}

// MARK: - Suggestion Evidence

struct SuggestionEvidence: Sendable, Codable, Equatable {
    var sourceFile: String
    var headerContext: String
    var text: String
    var score: Double
}

// MARK: - Suggestion Decision (Surfacing Gate)

struct SuggestionDecision: Sendable, Codable, Equatable {
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

struct KBResult: Identifiable, Sendable, Codable, Equatable {
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

// MARK: - KB Context Pack

/// Rich KB context preserving document structure for display and synthesis.
struct KBContextPack: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let matchedText: String
    let relativePath: String      // e.g. "sales/pricing.md"
    let folderBreadcrumb: String  // e.g. "sales"
    let documentTitle: String     // first H1 or filename
    let headerBreadcrumb: String  // e.g. "Pricing > Unit Economics"
    let score: Double
    let previousSiblingText: String?
    let nextSiblingText: String?

    init(
        matchedText: String,
        relativePath: String,
        folderBreadcrumb: String = "",
        documentTitle: String = "",
        headerBreadcrumb: String = "",
        score: Double,
        previousSiblingText: String? = nil,
        nextSiblingText: String? = nil
    ) {
        self.id = UUID()
        self.matchedText = matchedText
        self.relativePath = relativePath
        self.folderBreadcrumb = folderBreadcrumb
        self.documentTitle = documentTitle
        self.headerBreadcrumb = headerBreadcrumb
        self.score = score
        self.previousSiblingText = previousSiblingText
        self.nextSiblingText = nextSiblingText
    }

    /// Display breadcrumb: "sales/pricing.md > Pricing > Unit Economics"
    var displayBreadcrumb: String {
        var parts: [String] = []
        if !relativePath.isEmpty { parts.append(relativePath) }
        if !headerBreadcrumb.isEmpty { parts.append(headerBreadcrumb) }
        return parts.joined(separator: " > ")
    }
}

// MARK: - Realtime Suggestion

enum SuggestionLifecycle: String, Codable, Sendable {
    case raw         // KB snippet shown, no LLM yet
    case streaming   // LLM synthesis in progress
    case completed   // LLM synthesis finished
    case failed      // LLM call failed, raw snippet preserved
    case superseded  // Replaced by a newer suggestion
}

/// A real-time suggestion with stable identity across its lifecycle.
struct RealtimeSuggestion: Identifiable, Sendable, Equatable {
    let id: UUID
    let triggerKind: RealtimeTriggerKind
    let triggerExcerpt: String
    let triggerUtteranceID: UUID?
    let contextPacks: [KBContextPack]
    let candidateScore: Double
    let createdAt: Date
    var lifecycle: SuggestionLifecycle
    var synthesizedText: String

    /// First context pack's matched text.
    var rawSnippet: String { contextPacks.first?.matchedText ?? "" }

    init(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        triggerUtteranceID: UUID? = nil,
        contextPacks: [KBContextPack],
        candidateScore: Double
    ) {
        self.id = UUID()
        self.triggerKind = triggerKind
        self.triggerExcerpt = triggerExcerpt
        self.triggerUtteranceID = triggerUtteranceID
        self.contextPacks = contextPacks
        self.candidateScore = candidateScore
        self.createdAt = .now
        self.lifecycle = .raw
        self.synthesizedText = ""
    }

    /// The best available text for display.
    var displayText: String {
        synthesizedText.isEmpty ? rawSnippet : synthesizedText
    }

    /// The primary source breadcrumb for display.
    var sourceBreadcrumb: String {
        contextPacks.first?.displayBreadcrumb ?? ""
    }
}

// MARK: - Realtime Suggestion Candidate

/// Output of the local heuristic gate — passed to Layer 3 for synthesis.
struct RealtimeSuggestionCandidate: Sendable, Equatable {
    let triggerKind: RealtimeTriggerKind
    let triggerExcerpt: String
    let triggerUtteranceID: UUID?
    let triggerFingerprint: String?
    let contextPacks: [KBContextPack]
    let score: Double
    let createdAt: Date

    init(
        triggerKind: RealtimeTriggerKind,
        triggerExcerpt: String,
        triggerUtteranceID: UUID? = nil,
        triggerFingerprint: String? = nil,
        contextPacks: [KBContextPack],
        score: Double
    ) {
        self.triggerKind = triggerKind
        self.triggerExcerpt = triggerExcerpt
        self.triggerUtteranceID = triggerUtteranceID
        self.triggerFingerprint = triggerFingerprint
        self.contextPacks = contextPacks
        self.score = score
        self.createdAt = .now
    }

    /// Whether this candidate is too old to surface (e.g. KB results arrived after speech moved on).
    var isStale: Bool {
        Date.now.timeIntervalSince(createdAt) > 8
    }
}

// MARK: - Suggestion

struct Suggestion: Identifiable, Sendable, Codable, Equatable {
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
    let cleanedText: String?
    // Real-time suggestion tracking
    let suggestionID: UUID?
    let triggerUtteranceID: UUID?
    let suggestionLifecycle: SuggestionLifecycle?

    enum CodingKeys: String, CodingKey {
        case speaker, text, timestamp, suggestions, kbHits
        case suggestionDecision, surfacedSuggestionText, conversationStateSummary
        case cleanedText = "refinedText"
        case suggestionID, triggerUtteranceID, suggestionLifecycle
    }

    init(
        speaker: Speaker,
        text: String,
        timestamp: Date,
        suggestions: [String]? = nil,
        kbHits: [String]? = nil,
        suggestionDecision: SuggestionDecision? = nil,
        surfacedSuggestionText: String? = nil,
        conversationStateSummary: String? = nil,
        cleanedText: String? = nil,
        suggestionID: UUID? = nil,
        triggerUtteranceID: UUID? = nil,
        suggestionLifecycle: SuggestionLifecycle? = nil
    ) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.suggestions = suggestions
        self.kbHits = kbHits
        self.suggestionDecision = suggestionDecision
        self.surfacedSuggestionText = surfacedSuggestionText
        self.conversationStateSummary = conversationStateSummary
        self.cleanedText = cleanedText
        self.suggestionID = suggestionID
        self.triggerUtteranceID = triggerUtteranceID
        self.suggestionLifecycle = suggestionLifecycle
    }

    func withCleanedText(_ text: String?) -> SessionRecord {
        SessionRecord(
            speaker: speaker, text: self.text, timestamp: timestamp,
            suggestions: suggestions, kbHits: kbHits,
            suggestionDecision: suggestionDecision,
            surfacedSuggestionText: surfacedSuggestionText,
            conversationStateSummary: conversationStateSummary,
            cleanedText: text,
            suggestionID: suggestionID,
            triggerUtteranceID: triggerUtteranceID,
            suggestionLifecycle: suggestionLifecycle
        )
    }
}

// MARK: - Meeting Templates & Generated Notes

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

struct GeneratedNotes: Codable, Sendable {
    let template: TemplateSnapshot
    let generatedAt: Date
    let markdown: String
}

enum SessionAudioSourceKind: String, Sendable, Hashable {
    case recording
    case system
    case microphone

    var displayName: String {
        switch self {
        case .recording:
            return "Recording"
        case .system:
            return "System audio"
        case .microphone:
            return "Microphone"
        }
    }
}

struct SessionAudioSource: Identifiable, Sendable, Hashable {
    let kind: SessionAudioSourceKind
    let url: URL

    var id: String { "\(kind.rawValue):\(url.path)" }
    var displayName: String { kind.displayName }
}

struct SessionIndex: Identifiable, Codable, Sendable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var templateSnapshot: TemplateSnapshot?
    var title: String?
    var utteranceCount: Int
    var hasNotes: Bool
    /// BCP 47 language/locale used for transcription (e.g. "en-US", "fr-FR").
    var language: String?
    /// The detected meeting application name (e.g. "Zoom", "Microsoft Teams").
    var meetingApp: String?
    /// The ASR engine used for transcription (e.g. "parakeetV2").
    var engine: String?
    /// User-assigned tags for session organization.
    var tags: [String]?
    /// Optional slash-separated folder path used to organize sessions in the Notes UI.
    var folderPath: String? = nil
    /// How the session was created (nil for live sessions, "imported" for imported audio).
    var source: String?
}

struct SessionSidecar: Codable, Sendable {
    let index: SessionIndex
    var notes: GeneratedNotes?
}
