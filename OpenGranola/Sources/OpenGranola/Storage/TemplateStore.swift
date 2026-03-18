import Foundation
import Observation

@Observable
@MainActor
final class TemplateStore {
    private(set) var templates: [MeetingTemplate] = []
    private let storageURL: URL
    private var templateVersion: Int = 1

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OpenOats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("templates.json")
        load()
    }

    // MARK: - Deterministic Built-in IDs

    static let genericID   = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let oneOnOneID  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let discoveryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let hiringID    = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let standUpID   = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let weeklyID    = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    static let builtInTemplates: [MeetingTemplate] = [
        MeetingTemplate(
            id: genericID,
            name: "Generic",
            icon: "doc.text",
            systemPrompt: """
            You are a meeting notes assistant. Given a transcript of a meeting, produce structured notes in markdown.

            Include these sections:
            ## Summary
            A 2-3 sentence overview of what was discussed.

            ## Key Points
            Bullet points of the most important topics and insights.

            ## Action Items
            Bullet points of concrete next steps, with owners if mentioned.

            ## Decisions Made
            Any decisions that were reached during the meeting.

            ## Open Questions
            Unresolved questions or topics that need follow-up.
            """,
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: oneOnOneID,
            name: "1:1",
            icon: "person.2",
            systemPrompt: """
            You are a meeting notes assistant for a 1:1 meeting. Given a transcript, produce structured notes in markdown.

            Include these sections:
            ## Discussion Points
            Key topics that were covered.

            ## Action Items
            Concrete next steps with owners.

            ## Follow-ups
            Items that need follow-up in future 1:1s.

            ## Key Decisions
            Decisions that were made during the meeting.
            """,
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: discoveryID,
            name: "Customer Discovery",
            icon: "magnifyingglass",
            systemPrompt: """
            You are a meeting notes assistant for a customer discovery call. Given a transcript, produce structured notes in markdown.

            Include these sections:
            ## Customer Profile
            Who the customer is, their role, and context.

            ## Problems Identified
            Pain points and challenges the customer described.

            ## Current Solutions
            How they currently solve these problems.

            ## Key Insights
            Surprising or important learnings from the conversation.

            ## Next Steps
            Follow-up actions and commitments made.
            """,
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: hiringID,
            name: "Hiring",
            icon: "person.badge.plus",
            systemPrompt: """
            You are a meeting notes assistant for a hiring interview. Given a transcript, produce structured notes in markdown.

            Include these sections:
            ## Candidate Summary
            Brief overview of the candidate and role discussed.

            ## Strengths
            Areas where the candidate demonstrated strong capability.

            ## Concerns
            Potential red flags or areas needing further evaluation.

            ## Culture Fit
            Observations about alignment with team/company values.

            ## Recommendation
            Overall assessment and suggested next steps.
            """,
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: standUpID,
            name: "Stand-Up",
            icon: "arrow.up.circle",
            systemPrompt: """
            You are a meeting notes assistant for a stand-up meeting. Given a transcript, produce structured notes in markdown.

            Include these sections:
            ## Yesterday
            What was completed since the last stand-up.

            ## Today
            What each person plans to work on.

            ## Blockers
            Any obstacles or dependencies that need resolution.
            """,
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: weeklyID,
            name: "Weekly Meeting",
            icon: "calendar",
            systemPrompt: """
            You are a meeting notes assistant for a weekly team meeting. Given a transcript, produce structured notes in markdown.

            Include these sections:
            ## Updates
            Status updates from team members.

            ## Decisions Made
            Any decisions that were reached.

            ## Open Items
            Topics that need further discussion or action.

            ## Action Items
            Concrete next steps with owners and deadlines if mentioned.
            """,
            isBuiltIn: true
        ),
    ]

    // MARK: - CRUD

    func add(_ template: MeetingTemplate) {
        templates.append(template)
        save()
    }

    func update(_ template: MeetingTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
        save()
    }

    func delete(id: UUID) {
        guard let idx = templates.firstIndex(where: { $0.id == id }),
              !templates[idx].isBuiltIn else { return }
        templates.remove(at: idx)
        save()
    }

    func resetBuiltIn(id: UUID) {
        guard let builtIn = Self.builtInTemplates.first(where: { $0.id == id }),
              let idx = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[idx] = builtIn
        save()
    }

    func template(for id: UUID) -> MeetingTemplate? {
        templates.first { $0.id == id }
    }

    func snapshot(of template: MeetingTemplate) -> TemplateSnapshot {
        TemplateSnapshot(id: template.id, name: template.name, icon: template.icon, systemPrompt: template.systemPrompt)
    }

    // MARK: - Persistence

    private struct StorageFormat: Codable {
        var version: Int
        var templates: [MeetingTemplate]
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            templates = Self.builtInTemplates
            save()
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let stored = try JSONDecoder().decode(StorageFormat.self, from: data)
            templateVersion = stored.version
            templates = stored.templates

            // Ensure all built-ins exist (handles upgrades adding new built-ins)
            for builtIn in Self.builtInTemplates {
                if !templates.contains(where: { $0.id == builtIn.id }) {
                    templates.append(builtIn)
                }
            }
        } catch {
            print("TemplateStore: failed to load, using defaults: \(error)")
            templates = Self.builtInTemplates
        }
        save()
    }

    private func save() {
        let stored = StorageFormat(version: templateVersion, templates: templates)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("TemplateStore: failed to save: \(error)")
        }
    }
}
