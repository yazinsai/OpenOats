import XCTest
@testable import OpenOatsKit

@MainActor
final class IdleHomeDashboardReadinessTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        let suiteName = "com.openoats.tests.idle-dashboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("IdleDashboardReadinessTests"),
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    func testResolveReportsNoHistoryWhenMeetingFamilyHasNoSavedSessions() {
        let settings = makeSettings()
        let event = makeEvent(id: "evt-1", title: "Product Planning")

        let readiness = UpcomingMeetingReadiness.resolve(
            for: event,
            settings: settings,
            sessionHistory: []
        )

        XCTAssertEqual(readiness.historyCount, 0)
        XCTAssertNil(readiness.folderPath)
        XCTAssertEqual(readiness.summaryText, "No history")
    }

    func testResolveIncludesHistoryCountAndFolderPath() {
        let settings = makeSettings()
        let event = makeEvent(
            id: "evt-2",
            title: "Payment Ops / Merchant stand up",
            externalIdentifier: "series-merchant-standup"
        )
        settings.notesFolders = [
            NotesFolderDefinition(path: "Work/Standups", color: .orange)
        ]
        settings.setMeetingFamilyFolderPreference("Work/Standups", for: event)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionHistory = [
            SessionIndex(
                id: "older",
                startedAt: startedAt.addingTimeInterval(-600),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Payment Ops Merchant stand-up",
                utteranceCount: 8,
                hasNotes: true,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil,
                meetingFamilyKey: MeetingHistoryResolver.seriesHistoryKey(forExternalIdentifier: "series-merchant-standup")
            ),
            SessionIndex(
                id: "newer",
                startedAt: startedAt.addingTimeInterval(-120),
                endedAt: nil,
                templateSnapshot: nil,
                title: "Merchant standup",
                utteranceCount: 5,
                hasNotes: false,
                language: nil,
                meetingApp: nil,
                engine: nil,
                tags: nil,
                source: nil,
                meetingFamilyKey: MeetingHistoryResolver.seriesHistoryKey(forExternalIdentifier: "series-merchant-standup")
            ),
        ]

        let readiness = UpcomingMeetingReadiness.resolve(
            for: event,
            settings: settings,
            sessionHistory: sessionHistory
        )

        XCTAssertEqual(readiness.historyCount, 2)
        XCTAssertEqual(readiness.folderPath, "Work/Standups")
        XCTAssertEqual(readiness.summaryText, "2 previous")
    }

    private func makeEvent(
        id: String,
        title: String,
        externalIdentifier: String? = nil
    ) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return CalendarEvent(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(30 * 60),
            externalIdentifier: externalIdentifier,
            calendarID: nil,
            calendarTitle: nil,
            calendarColorHex: nil,
            organizer: nil,
            participants: [],
            isOnlineMeeting: true,
            meetingURL: nil
        )
    }
}
