import Foundation

struct SidecastPersona: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var subtitle: String
    var prompt: String
    var avatarSymbol: String
    var avatarTint: PersonaAvatarTint
    var avatarImagePath: String
    var verbosity: PersonaVerbosity
    var cadence: PersonaCadence
    var evidencePolicy: PersonaEvidencePolicy
    var isEnabled: Bool
    var webSearchEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        subtitle: String,
        prompt: String,
        avatarSymbol: String,
        avatarTint: PersonaAvatarTint,
        avatarImagePath: String = "",
        verbosity: PersonaVerbosity,
        cadence: PersonaCadence,
        evidencePolicy: PersonaEvidencePolicy,
        isEnabled: Bool = true,
        webSearchEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.prompt = prompt
        self.avatarSymbol = avatarSymbol
        self.avatarTint = avatarTint
        self.avatarImagePath = avatarImagePath
        self.verbosity = verbosity
        self.cadence = cadence
        self.evidencePolicy = evidencePolicy
        self.isEnabled = isEnabled
        self.webSearchEnabled = webSearchEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        prompt = try container.decode(String.self, forKey: .prompt)
        avatarSymbol = try container.decode(String.self, forKey: .avatarSymbol)
        avatarTint = try container.decode(PersonaAvatarTint.self, forKey: .avatarTint)
        avatarImagePath = try container.decode(String.self, forKey: .avatarImagePath)
        verbosity = try container.decode(PersonaVerbosity.self, forKey: .verbosity)
        cadence = try container.decode(PersonaCadence.self, forKey: .cadence)
        evidencePolicy = try container.decode(PersonaEvidencePolicy.self, forKey: .evidencePolicy)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        webSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? false
    }

    var avatarUsesImage: Bool {
        !avatarImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let starterPack: [SidecastPersona] = [
        SidecastPersona(
            name: "The Checker",
            subtitle: "Facts and missing nuance",
            prompt: "Verify claims with specific data: cite exact numbers, percentages, dates, dollar amounts, or named studies. Never make a general statement when a specific figure exists. If the speaker says something vague, counter with the precise number.",
            avatarSymbol: "checkmark.seal.fill",
            avatarTint: .green,
            verbosity: .short,
            cadence: .normal,
            evidencePolicy: .required,
            webSearchEnabled: true
        ),
        SidecastPersona(
            name: "The Archivist",
            subtitle: "Context and precedent",
            prompt: "Add useful background, comparisons, history, or precedent that helps the host understand what was just said.",
            avatarSymbol: "books.vertical.fill",
            avatarTint: .indigo,
            verbosity: .short,
            cadence: .normal,
            evidencePolicy: .preferred,
            webSearchEnabled: true
        ),
        SidecastPersona(
            name: "The Sniper",
            subtitle: "Punchy one-liners",
            prompt: "Write short, sharp, host-usable punch lines or callbacks. Prioritize timing and brevity over explanation.",
            avatarSymbol: "bolt.fill",
            avatarTint: .orange,
            verbosity: .terse,
            cadence: .rare,
            evidencePolicy: .optional
        ),
        SidecastPersona(
            name: "The Menace",
            subtitle: "Skeptic and chaos",
            prompt: "Inject pointed skepticism or contrarian heat without becoming abusive or unusably toxic. Make the tension entertaining.",
            avatarSymbol: "exclamationmark.bubble.fill",
            avatarTint: .red,
            verbosity: .terse,
            cadence: .rare,
            evidencePolicy: .optional
        ),
    ]
}

struct SidecastMessage: Identifiable, Sendable, Equatable {
    let id: UUID
    let personaID: UUID
    let personaName: String
    let text: String
    let timestamp: Date
    let confidence: Double
    let priority: Double
    let value: Double
    let sourceBreadcrumb: String

    init(
        id: UUID = UUID(),
        personaID: UUID,
        personaName: String,
        text: String,
        timestamp: Date = .now,
        confidence: Double = 0,
        priority: Double = 0,
        value: Double = 0.5,
        sourceBreadcrumb: String = ""
    ) {
        self.id = id
        self.personaID = personaID
        self.personaName = personaName
        self.text = text
        self.timestamp = timestamp
        self.confidence = confidence
        self.priority = priority
        self.value = value
        self.sourceBreadcrumb = sourceBreadcrumb
    }
}
