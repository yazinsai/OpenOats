import AppKit
import SwiftUI

struct IdleHomeDashboardView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var events: [CalendarEvent] = []
    @State private var refreshTick = 0

    var body: some View {
        let accessState = currentAccessState

        VStack(alignment: .leading, spacing: 8) {
            Text("Coming up")
                .font(.system(size: 24, weight: .semibold))

            comingUpCard(accessState: accessState)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .task(id: refreshTaskID(for: accessState)) {
            await refresh()
            try? await Task.sleep(for: refreshInterval(for: accessState))
            refreshTick &+= 1
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            refreshTick &+= 1
        }
    }

    @ViewBuilder
    private func comingUpCard(accessState: CalendarManager.AccessState) -> some View {
        Group {
            if !settings.calendarIntegrationEnabled {
                disabledCalendarCard
            } else {
                switch accessState {
                case .authorized:
                    if events.isEmpty {
                        emptyStateCard(
                            title: "No upcoming meetings",
                            description: "OpenOats will show your next calendar meetings here."
                        )
                    } else {
                        upcomingMeetingsCard
                    }
                case .denied:
                    deniedCalendarCard
                case .notDetermined:
                    emptyStateCard(
                        title: "Waiting for calendar access",
                        description: "OpenOats will show your upcoming meetings once Calendar access is granted."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var disabledCalendarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Calendar integration is off", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 14, weight: .medium))
            Text("Enable Calendar integration to see the meetings OpenOats can prepare for.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            SettingsLink {
                Label("Open Settings", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var deniedCalendarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Calendar access denied", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            Text("Grant Calendar access in System Settings to see upcoming meetings here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                openCalendarPrivacySettings()
            } label: {
                Label("Open Privacy Settings", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var upcomingMeetingsCard: some View {
        let groups = UpcomingCalendarGrouping.groups(for: events)
        let shouldShowCalendarTitle = UpcomingEventSelection.distinctCalendarCount(in: events) > 1

        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                ComingUpDayGroupView(
                    group: group,
                    showCalendarTitle: shouldShowCalendarTitle,
                    onJoinEvent: joinMeeting(for:),
                    onOpenRelatedNotes: openRelatedNotes(for:)
                )
                if index < groups.count - 1 {
                    Divider()
                        .padding(.top, 2)
                }
            }
        }
    }

    private func emptyStateCard(title: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "calendar")
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @MainActor
    private func refresh() async {
        guard settings.calendarIntegrationEnabled, let manager = container.calendarManager else {
            events = []
            return
        }

        guard manager.accessState == .authorized else {
            events = []
            return
        }

        let now = Date()
        let currentEvent = manager.currentEvent(at: now)
        let upcomingEvents = manager.upcomingEvents(
            from: now,
            within: 7 * 24 * 60 * 60,
            limit: 24
        )

        var combined: [CalendarEvent] = []
        if let currentEvent {
            combined.append(currentEvent)
        }

        let remainingLimit = max(0, 6 - combined.count)
        let selectedUpcoming = UpcomingEventSelection.select(
            from: upcomingEvents.filter { $0.id != currentEvent?.id },
            limit: remainingLimit
        )
        combined.append(contentsOf: selectedUpcoming)
        events = combined
    }

    private var currentAccessState: CalendarManager.AccessState {
        guard settings.calendarIntegrationEnabled else { return .notDetermined }
        return container.calendarManager?.accessState ?? .notDetermined
    }

    private func refreshTaskID(for accessState: CalendarManager.AccessState) -> String {
        "\(settings.calendarIntegrationEnabled)-\(accessStateTag(for: accessState))-\(refreshTick)"
    }

    private func accessStateTag(for accessState: CalendarManager.AccessState) -> String {
        switch accessState {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not-determined"
        }
    }

    private func refreshInterval(for accessState: CalendarManager.AccessState) -> Duration {
        switch accessState {
        case .authorized:
            return .seconds(60)
        case .denied:
            return .seconds(300)
        case .notDetermined:
            return .seconds(1)
        }
    }

    private func openCalendarPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private func joinMeeting(for event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func openRelatedNotes(for event: CalendarEvent) {
        coordinator.queueMeetingHistory(event)
        openWindow(id: "notes")
    }
}

private struct ComingUpDayGroupView: View {
    let group: UpcomingCalendarGrouping.DayGroup
    let showCalendarTitle: Bool
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenRelatedNotes: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.sectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.events) { event in
                    ComingUpEventRow(
                        event: event,
                        showCalendarTitle: showCalendarTitle,
                        onJoinEvent: onJoinEvent,
                        onOpenRelatedNotes: onOpenRelatedNotes
                    )
                }
            }
        }
    }
}

private struct ComingUpEventRow: View {
    let event: CalendarEvent
    let showCalendarTitle: Bool
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenRelatedNotes: (CalendarEvent) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: {
                onOpenRelatedNotes(event)
            }) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(calendarColor(for: event))
                        .frame(width: 4, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Text(secondaryLine(for: event))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }
            .help("Open meeting history")
            .accessibilityIdentifier("idle.comingUp.event.\(event.id)")

            if event.meetingURL != nil {
                Button(action: {
                    onJoinEvent(event)
                }) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Join meeting")
                .accessibilityIdentifier("idle.comingUp.join.\(event.id)")
            }
        }
    }

    private func secondaryLine(for event: CalendarEvent) -> String {
        let time = CalendarEventDisplay.timeRange(for: event)
        guard showCalendarTitle,
              let calendarTitle = event.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !calendarTitle.isEmpty else {
            return time
        }
        return "\(time)  •  \(calendarTitle)"
    }

    private func calendarColor(for event: CalendarEvent) -> Color {
        guard let hex = event.calendarColorHex,
              let color = CalendarColorCodec.color(from: hex) else {
            return .accentColor
        }
        return color
    }
}

extension CalendarColorCodec {
    static func color(from hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 7, cleaned.hasPrefix("#") else { return nil }

        let start = cleaned.index(after: cleaned.startIndex)
        let hexDigits = String(cleaned[start...])
        guard let value = Int(hexDigits, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

enum UpcomingEventSelection {
    static func select(from events: [CalendarEvent], limit: Int) -> [CalendarEvent] {
        guard limit > 0, events.count > limit else {
            return Array(events.prefix(limit))
        }

        let sortedEvents = events.sorted { $0.startDate < $1.startDate }
        var selectedIDs = Set<String>()
        var selected: [CalendarEvent] = []

        for event in earliestPerCalendar(in: sortedEvents) {
            guard selected.count < limit else { break }
            guard selectedIDs.insert(event.id).inserted else { continue }
            selected.append(event)
        }

        for event in sortedEvents {
            guard selected.count < limit else { break }
            guard selectedIDs.insert(event.id).inserted else { continue }
            selected.append(event)
        }

        return selected.sorted { $0.startDate < $1.startDate }
    }

    static func distinctCalendarCount(in events: [CalendarEvent]) -> Int {
        Set(events.map(calendarIdentity(for:))).count
    }

    private static func earliestPerCalendar(in events: [CalendarEvent]) -> [CalendarEvent] {
        var firstByCalendar: [String: CalendarEvent] = [:]
        for event in events {
            let identity = calendarIdentity(for: event)
            if firstByCalendar[identity] == nil {
                firstByCalendar[identity] = event
            }
        }
        return firstByCalendar.values.sorted { $0.startDate < $1.startDate }
    }

    private static func calendarIdentity(for event: CalendarEvent) -> String {
        if let calendarID = event.calendarID, !calendarID.isEmpty {
            return calendarID
        }
        if let calendarTitle = event.calendarTitle, !calendarTitle.isEmpty {
            return "title:\(calendarTitle)"
        }
        return "event:\(event.id)"
    }
}

enum UpcomingCalendarGrouping {
    struct DayGroup: Identifiable, Equatable {
        let date: Date
        let events: [CalendarEvent]

        var id: Date { date }

        var dayNumber: String {
            Self.dayNumberFormatter.string(from: date)
        }

        var monthText: String {
            Self.monthFormatter.string(from: date)
        }

        var weekdayText: String {
            Self.weekdayFormatter.string(from: date)
        }

        var sectionTitle: String {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return "Today"
            }
            if calendar.isDateInTomorrow(date) {
                return "Tomorrow"
            }
            return "\(weekdayText), \(dayNumber) \(monthText)"
        }

        private static let dayNumberFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "d"
            return formatter
        }()

        private static let monthFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            return formatter
        }()

        private static let weekdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter
        }()
    }

    static func groups(
        for events: [CalendarEvent],
        calendar: Calendar = .current
    ) -> [DayGroup] {
        let grouped = Dictionary(grouping: events) { event in
            calendar.startOfDay(for: event.startDate)
        }

        return grouped.keys.sorted().map { day in
            DayGroup(
                date: day,
                events: grouped[day, default: []]
                    .sorted { $0.startDate < $1.startDate }
            )
        }
    }
}
