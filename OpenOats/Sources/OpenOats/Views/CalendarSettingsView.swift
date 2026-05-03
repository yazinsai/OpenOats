import AppKit
import SwiftUI

struct CalendarSettingsTab: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container

    @State private var accessState: CalendarManager.AccessState = .notDetermined
    @State private var availableCalendars: [CalendarManager.AvailableCalendar] = []
    @State private var refreshTick: Int = 0
    @State private var isManualRefreshInFlight = false
    @State private var showReloadSuccess = false
    @State private var reloadErrorMessage: String?

    private struct CalendarSourceGroup: Identifiable {
        let title: String
        let calendars: [CalendarManager.AvailableCalendar]

        var id: String { title }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accessCard

                if settings.calendarIntegrationEnabled {
                    switch accessState {
                    case .authorized:
                        calendarsCard
                        cloudSharingCard
                    case .denied, .notDetermined:
                        EmptyView()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            syncCalendarIntegration()
            refreshTick &+= 1
        }
        .task(id: refreshTaskID) {
            await refresh()
            guard settings.calendarIntegrationEnabled else { return }
            try? await Task.sleep(for: .seconds(30))
            refreshTick &+= 1
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            syncCalendarIntegration()
            refreshTick &+= 1
        }
        .onChange(of: settings.excludedCalendarIDs) {
            refreshTick &+= 1
        }
    }

    private var refreshTaskID: String {
        "\(settings.calendarIntegrationEnabled)-\(settings.excludedCalendarIDs.joined(separator: ","))-\(refreshTick)"
    }

    private var selectedCalendarCount: Int {
        let excluded = Set(settings.excludedCalendarIDs)
        return availableCalendars.filter { !excluded.contains($0.id) }.count
    }

    private var calendarSelectionSummary: String {
        guard !availableCalendars.isEmpty else {
            return "No calendars available"
        }
        if selectedCalendarCount == 0 {
            return "No calendars selected"
        }
        if selectedCalendarCount == availableCalendars.count {
            return availableCalendars.count == 1
                ? "1 calendar selected"
                : "All \(availableCalendars.count) calendars selected"
        }
        return "\(selectedCalendarCount) of \(availableCalendars.count) calendars selected"
    }

    private var calendarGroups: [CalendarSourceGroup] {
        var groups: [CalendarSourceGroup] = []
        var currentTitle: String?
        var currentCalendars: [CalendarManager.AvailableCalendar] = []

        for calendar in availableCalendars {
            let title = calendar.sourceTitle ?? "Other"
            if currentTitle == title {
                currentCalendars.append(calendar)
            } else {
                if let currentTitle {
                    groups.append(CalendarSourceGroup(title: currentTitle, calendars: currentCalendars))
                }
                currentTitle = title
                currentCalendars = [calendar]
            }
        }

        if let currentTitle {
            groups.append(CalendarSourceGroup(title: currentTitle, calendars: currentCalendars))
        }

        return groups
    }

    private var accessCard: some View {
        settingsCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Use macOS Calendar to match meetings and title sessions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if settings.calendarIntegrationEnabled {
                    refreshButton
                }
            }

            Toggle("Use Calendar to identify meetings", isOn: $settings.calendarIntegrationEnabled)
                .font(.system(size: 12))

            Divider()

            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                Text(statusLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if accessState == .authorized, !availableCalendars.isEmpty {
                    Text("\(availableCalendars.count) visible")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            accessDetail
        }
    }

    private var cloudSharingCard: some View {
        settingsCard {
            Text("Cloud Notes")
                .font(.system(size: 15, weight: .semibold))

            Toggle("Share calendar details with cloud notes", isOn: $settings.shareCalendarContextWithCloudNotes)
                .font(.system(size: 12))

            Text("Remote note providers may receive event title, organizer, and invited participant names as text context. Local providers are excluded.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var calendarsCard: some View {
        settingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Included Calendars")
                        .font(.system(size: 15, weight: .semibold))
                    Text(calendarSelectionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("All") {
                        settings.excludedCalendarIDs = []
                    }
                    .font(.system(size: 12))
                    .disabled(availableCalendars.isEmpty || selectedCalendarCount == availableCalendars.count)
                    .help("Include all calendars")

                    Button("None") {
                        settings.excludedCalendarIDs = availableCalendars.map(\.id)
                    }
                    .font(.system(size: 12))
                    .disabled(availableCalendars.isEmpty || selectedCalendarCount == 0)
                    .help("Exclude all calendars")
                }
            }

            Text("Choose which calendars OpenOats can use when matching meetings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if availableCalendars.isEmpty {
                Text("No calendars are currently available from macOS Calendar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(calendarGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(Array(group.calendars.enumerated()), id: \.element.id) { index, calendar in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Toggle(isOn: inclusionBinding(for: calendar.id)) {
                                            HStack(spacing: 8) {
                                                Circle()
                                                    .fill(calendarColor(for: calendar))
                                                    .frame(width: 8, height: 8)
                                                Text(calendar.title)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                        .toggleStyle(.checkbox)

                                        if index < group.calendars.count - 1 {
                                            Divider()
                                                .padding(.leading, 28)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(cardInsetBackground)
            }
        }
    }

    private var refreshButton: some View {
        Group {
            if isManualRefreshInFlight {
                Label {
                    Text("Reloading…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .font(.system(size: 12))
            } else {
                Button {
                    reloadErrorMessage = nil
                    showReloadSuccess = false
                    Task {
                        container.reloadCalendarIntegration()
                        await refresh(showManualProgress: true)
                    }
                } label: {
                    Label(showReloadSuccess ? "Updated" : "Reload", systemImage: showReloadSuccess ? "checkmark" : "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Reload calendar access and the visible calendar list")
            }
        }
    }

    @ViewBuilder
    private var accessDetail: some View {
        switch accessState {
        case .authorized:
            if let reloadErrorMessage {
                Text(reloadErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendar access is denied. Grant access in System Settings for OpenOats to see your events.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings…") {
                    openCalendarPrivacySettings()
                }
                .font(.system(size: 12))
            }
        case .notDetermined:
            Text("OpenOats will request Calendar access when this setting is enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        switch accessState {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notDetermined: return "clock"
        }
    }

    private var statusColor: Color {
        switch accessState {
        case .authorized: return .green
        case .denied: return .orange
        case .notDetermined: return .secondary
        }
    }

    private var statusLabel: String {
        switch accessState {
        case .authorized: return "Calendar access authorized"
        case .denied: return "Calendar access denied"
        case .notDetermined: return "Calendar access not yet requested"
        }
    }

    private func inclusionBinding(for calendarID: String) -> Binding<Bool> {
        Binding(
            get: { !settings.excludedCalendarIDs.contains(calendarID) },
            set: { isIncluded in
                var excluded = Set(settings.excludedCalendarIDs)
                if isIncluded {
                    excluded.remove(calendarID)
                } else {
                    excluded.insert(calendarID)
                }
                settings.excludedCalendarIDs = availableCalendars.map(\.id).filter { excluded.contains($0) }
            }
        )
    }

    @MainActor
    private func refresh(showManualProgress: Bool = false) async {
        let refreshStart = ContinuousClock.now
        if showManualProgress {
            isManualRefreshInFlight = true
        }
        defer {
            if showManualProgress {
                Task { @MainActor in
                    let minimumVisibleDuration = Duration.milliseconds(400)
                    let elapsed = refreshStart.duration(to: ContinuousClock.now)
                    if elapsed < minimumVisibleDuration {
                        try? await Task.sleep(for: minimumVisibleDuration - elapsed)
                    }
                    isManualRefreshInFlight = false
                }
            }
        }

        guard settings.calendarIntegrationEnabled else {
            accessState = .notDetermined
            availableCalendars = []
            reloadErrorMessage = nil
            showReloadSuccess = false
            return
        }

        if container.calendarManager == nil {
            syncCalendarIntegration()
        }

        guard let manager = container.calendarManager else {
            accessState = .notDetermined
            availableCalendars = []
            reloadErrorMessage = "Could not reload Calendar access."
            return
        }

        manager.refreshFromSystem()
        accessState = manager.accessState

        guard manager.accessState == .authorized else {
            availableCalendars = []
            reloadErrorMessage = nil
            showReloadSuccess = true
            clearReloadSuccessSoon()
            return
        }

        let calendars = manager.availableCalendars()
        availableCalendars = calendars

        let availableIDs = Set(calendars.map(\.id))
        let prunedExcludedIDs = settings.excludedCalendarIDs.filter { availableIDs.contains($0) }
        if prunedExcludedIDs != settings.excludedCalendarIDs {
            settings.excludedCalendarIDs = prunedExcludedIDs
        }
        reloadErrorMessage = nil
        if showManualProgress {
            showReloadSuccess = true
            clearReloadSuccessSoon()
        }
    }

    private func syncCalendarIntegration() {
        container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
    }

    private func clearReloadSuccessSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !isManualRefreshInFlight else { return }
            showReloadSuccess = false
        }
    }

    private func calendarColor(for calendar: CalendarManager.AvailableCalendar) -> Color {
        guard let hex = calendar.colorHex,
              let color = Color(calendarHex: hex) else { return .secondary }
        return color
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
            )
    }

    private var cardInsetBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.15), lineWidth: 1)
            )
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
}

private extension Color {
    init?(calendarHex: String) {
        let cleaned = calendarHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 7, cleaned.hasPrefix("#") else { return nil }
        let redString = String(cleaned.dropFirst().prefix(2))
        let greenString = String(cleaned.dropFirst(3).prefix(2))
        let blueString = String(cleaned.dropFirst(5).prefix(2))
        guard let red = UInt8(redString, radix: 16),
              let green = UInt8(greenString, radix: 16),
              let blue = UInt8(blueString, radix: 16) else { return nil }
        self = Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}
