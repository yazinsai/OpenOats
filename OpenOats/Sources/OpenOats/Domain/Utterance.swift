import Foundation

// MARK: - Speaker

enum Speaker: Codable, Sendable, Hashable {
    case you
    case them
    case remote(Int)

    var displayLabel: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Speaker \(n)"
        }
    }

    /// True for any non-mic speaker (.them or .remote).
    var isRemote: Bool {
        switch self {
        case .you: false
        case .them, .remote: true
        }
    }

    /// Stable key for persistence (JSONL encoding, backfill dedup).
    var storageKey: String {
        switch self {
        case .you: "you"
        case .them: "them"
        case .remote(let n): "remote_\(n)"
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "you": self = .you
        case "them": self = .them
        default:
            if raw.hasPrefix("remote_"), let n = Int(raw.dropFirst("remote_".count)) {
                self = .remote(n)
            } else {
                self = .them
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}

// MARK: - Refinement Status

enum RefinementStatus: String, Codable, Sendable {
    case pending, completed, failed, skipped
}

// MARK: - Utterance

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
