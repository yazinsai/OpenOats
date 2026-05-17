import Foundation

@MainActor
enum NotesTemplateResolver {
    static func resolve(
        templateStore: TemplateStore,
        settings: AppSettings?,
        sessionTemplateSnapshot: TemplateSnapshot?,
        meetingFamilyEvent: CalendarEvent? = nil,
        meetingFamilyKey: String? = nil
    ) -> MeetingTemplate? {
        if let explicitSessionTemplate = explicitSessionTemplate(
            from: sessionTemplateSnapshot,
            templateStore: templateStore
        ) {
            return explicitSessionTemplate
        }

        if let settings {
            if let preferredID = meetingFamilyEvent.flatMap({ settings.meetingFamilyPreferences(for: $0)?.templateID }),
               let template = templateStore.template(for: preferredID) {
                return template
            }

            if let meetingFamilyKey,
               let preferredID = settings.meetingFamilyPreferences(forHistoryKey: meetingFamilyKey)?.templateID,
               let template = templateStore.template(for: preferredID) {
                return template
            }

            if let defaultTemplateID = settings.defaultNotesTemplateID,
               let template = templateStore.template(for: defaultTemplateID) {
                return template
            }
        }

        if let sessionTemplate = sessionTemplate(from: sessionTemplateSnapshot, templateStore: templateStore) {
            return sessionTemplate
        }

        return templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first
    }

    private static func explicitSessionTemplate(
        from snapshot: TemplateSnapshot?,
        templateStore: TemplateStore
    ) -> MeetingTemplate? {
        guard let snapshot, snapshot.id != TemplateStore.genericID else { return nil }
        return sessionTemplate(from: snapshot, templateStore: templateStore)
    }

    private static func sessionTemplate(
        from snapshot: TemplateSnapshot?,
        templateStore: TemplateStore
    ) -> MeetingTemplate? {
        guard let snapshot else { return nil }
        return templateStore.template(for: snapshot.id)
            ?? MeetingTemplate(
                id: snapshot.id,
                name: snapshot.name,
                icon: snapshot.icon,
                systemPrompt: snapshot.systemPrompt,
                isBuiltIn: false
            )
    }
}
