import AppKit
import SwiftUI

struct IdleHomeDashboardView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var events: [CalendarEvent] = []
    @State private var earlierTodayEvents: [CalendarEvent] = []
    @State private var showsEarlierToday = false
    @State private var refreshTick = 0
    @State private var creatingFolderEvent: CalendarEvent?
    @State private var pendingMeetingFamilyFolderChange: PendingMeetingFamilyFolderChange?
    @State private var newFolderPath = ""
    @State private var newFolderColor: NotesFolderColor = .orange
    @FocusState private var newFolderFieldFocused: Bool

    private struct PendingMeetingFamilyFolderChange: Equatable {
        let historyKey: String
        let familyTitle: String
        let folderPath: String?
        let existingMeetingCount: Int
    }

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
        .sheet(
            isPresented: Binding(
                get: { creatingFolderEvent != nil },
                set: { if !$0 { cancelCreateFolder() } }
            )
        ) {
            comingUpFolderSheet
        }
        .confirmationDialog(
            "Update default folder?",
            isPresented: Binding(
                get: { pendingMeetingFamilyFolderChange != nil },
                set: { if !$0 { pendingMeetingFamilyFolderChange = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMeetingFamilyFolderChange
        ) { pendingChange in
            Button("Future meetings only") {
                applyPendingMeetingFamilyFolderChange(moveExistingSessions: false)
            }

            Button(moveExistingMeetingsTitle(for: pendingChange)) {
                applyPendingMeetingFamilyFolderChange(moveExistingSessions: true)
            }

            Button("Cancel", role: .cancel) {
                pendingMeetingFamilyFolderChange = nil
            }
        } message: { pendingChange in
            Text(meetingFamilyFolderChangeMessage(for: pendingChange))
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
                    if events.isEmpty && earlierTodayEvents.isEmpty {
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
        let groups = ComingUpDayGroupSelection.groups(
            for: events,
            earlierTodayEvents: earlierTodayEvents
        )
        let shouldShowCalendarTitle = UpcomingEventSelection.distinctCalendarCount(in: events) > 1

        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                ComingUpDayGroupView(
                    group: group,
                    showCalendarTitle: shouldShowCalendarTitle,
                    settings: settings,
                    sessionHistory: coordinator.sessionHistory,
                    earlierTodayEvents: Calendar.current.isDateInToday(group.date) ? earlierTodayEvents : [],
                    showsEarlierToday: Calendar.current.isDateInToday(group.date) ? showsEarlierToday : false,
                    onToggleEarlierToday: { showsEarlierToday.toggle() },
                    onJoinEvent: joinMeeting(for:),
                    onOpenRelatedNotes: openRelatedNotes(for:),
                    onRequestMeetingFamilyFolderChange: requestMeetingFamilyFolderChange(_:for:),
                    onCreateFolder: beginCreateFolder(for:)
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
            earlierTodayEvents = []
            return
        }

        guard manager.accessState == .authorized else {
            events = []
            earlierTodayEvents = []
            return
        }

        let now = Date()
        let currentEvent = manager.currentEvent(at: now)
        let dayEvents = manager.events(onSameDayAs: now)
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

        earlierTodayEvents = EarlierTodaySelection.select(
            from: dayEvents,
            now: now,
            currentEventID: currentEvent?.id
        )
        if earlierTodayEvents.isEmpty {
            showsEarlierToday = false
        }
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
        if event.endDate <= Date() {
            coordinator.queueManualTranscript(event)
        } else {
            coordinator.queueMeetingHistory(event)
        }
        openWindow(id: "notes")
    }

    private func beginCreateFolder(for event: CalendarEvent) {
        let preferredFolderPath = settings.meetingFamilyPreferences(for: event)?.folderPath
        newFolderPath = preferredFolderPath ?? ""
        newFolderColor = folderDefinition(for: preferredFolderPath)?.color ?? .orange
        creatingFolderEvent = event
    }

    private func cancelCreateFolder() {
        creatingFolderEvent = nil
        newFolderPath = ""
        newFolderColor = .orange
        newFolderFieldFocused = false
    }

    @ViewBuilder
    private var comingUpFolderSheet: some View {
        if let event = creatingFolderEvent {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Default Folder")
                    .font(.headline)

                Text("Use a top-level folder and at most one subfolder, like `Work` or `Work/1:1s`.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("e.g. Work/1:1s", text: $newFolderPath)
                    .textFieldStyle(.roundedBorder)
                    .focused($newFolderFieldFocused)
                    .onAppear {
                        newFolderFieldFocused = true
                    }
                    .onSubmit {
                        commitCreateFolder(for: event)
                    }

                folderColorGrid(selectedColor: $newFolderColor)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        cancelCreateFolder()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Create") {
                        commitCreateFolder(for: event)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedMeetingFamilyFolderPath(newFolderPath) == nil)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private func folderColorGrid(selectedColor: Binding<NotesFolderColor>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 4), spacing: 8) {
                ForEach(NotesFolderColor.allCases) { color in
                    Button {
                        selectedColor.wrappedValue = color
                    } label: {
                        ZStack {
                            Circle()
                                .fill(folderColor(for: color))
                                .frame(width: 18, height: 18)
                            if selectedColor.wrappedValue == color {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .stroke(
                                    selectedColor.wrappedValue == color ? Color.primary.opacity(0.35) : Color.secondary.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(color.displayName)
                }
            }
        }
    }

    private func commitCreateFolder(for event: CalendarEvent) {
        guard let normalizedPath = normalizedMeetingFamilyFolderPath(newFolderPath) else { return }

        var folders = settings.notesFolders
        if let existingIndex = folders.firstIndex(where: { $0.path.caseInsensitiveCompare(normalizedPath) == .orderedSame }) {
            folders[existingIndex].color = newFolderColor
        } else {
            folders.append(NotesFolderDefinition(path: normalizedPath, color: newFolderColor))
        }
        settings.notesFolders = folders
        requestMeetingFamilyFolderChange(normalizedPath, for: event)
        cancelCreateFolder()
    }

    private func requestMeetingFamilyFolderChange(_ folderPath: String?, for event: CalendarEvent) {
        let historyKey = settings.canonicalMeetingHistoryKey(for: event)
        let currentFolderPath = settings.meetingFamilyPreferences(forHistoryKey: historyKey)?.folderPath
        guard currentFolderPath != folderPath else { return }

        let existingMeetingCount = matchingSavedMeetingCount(forHistoryKey: historyKey)
        if existingMeetingCount > 0 {
            pendingMeetingFamilyFolderChange = PendingMeetingFamilyFolderChange(
                historyKey: historyKey,
                familyTitle: event.title,
                folderPath: folderPath,
                existingMeetingCount: existingMeetingCount
            )
            return
        }

        applyMeetingFamilyFolderPreference(
            folderPath,
            moveExistingSessions: false,
            forHistoryKey: historyKey
        )
    }

    private func applyPendingMeetingFamilyFolderChange(moveExistingSessions: Bool) {
        guard let pendingChange = pendingMeetingFamilyFolderChange else { return }
        applyMeetingFamilyFolderPreference(
            pendingChange.folderPath,
            moveExistingSessions: moveExistingSessions,
            forHistoryKey: pendingChange.historyKey
        )
        pendingMeetingFamilyFolderChange = nil
    }

    private func applyMeetingFamilyFolderPreference(
        _ folderPath: String?,
        moveExistingSessions: Bool,
        forHistoryKey historyKey: String
    ) {
        settings.setMeetingFamilyFolderPreference(folderPath, forHistoryKey: historyKey)

        guard moveExistingSessions else { return }

        let sessionIDs = MeetingHistoryResolver.matchingSessions(
            forHistoryKey: historyKey,
            sessionHistory: coordinator.sessionHistory,
            aliases: settings.meetingHistoryAliasesByKey
        ).map(\.id)

        Task {
            for sessionID in sessionIDs {
                await coordinator.sessionRepository.updateSessionFolder(sessionID: sessionID, folderPath: folderPath)
            }
            await coordinator.loadHistory()
        }
    }

    private func matchingSavedMeetingCount(forHistoryKey historyKey: String) -> Int {
        MeetingHistoryResolver.matchingSessions(
            forHistoryKey: historyKey,
            sessionHistory: coordinator.sessionHistory,
            aliases: settings.meetingHistoryAliasesByKey
        ).count
    }

    private func moveExistingMeetingsTitle(for pendingChange: PendingMeetingFamilyFolderChange) -> String {
        let count = pendingChange.existingMeetingCount
        return count == 1 ? "Move 1 saved meeting too" : "Move \(count) saved meetings too"
    }

    private func meetingFamilyFolderChangeMessage(for pendingChange: PendingMeetingFamilyFolderChange) -> String {
        let destination = folderDisplayName(for: pendingChange.folderPath)
        let count = pendingChange.existingMeetingCount
        let noun = count == 1 ? "saved meeting" : "saved meetings"
        return "Use \(destination) for future meetings in \"\(pendingChange.familyTitle)\", or move the existing \(count) \(noun) there too."
    }

    private func normalizedMeetingFamilyFolderPath(_ rawPath: String) -> String? {
        guard let normalized = NotesFolderDefinition.normalizePath(rawPath) else { return nil }
        return normalized.split(separator: "/").count <= 2 ? normalized : nil
    }

    private func folderDefinition(for folderPath: String?) -> NotesFolderDefinition? {
        guard let folderPath else { return nil }
        return settings.notesFolders.first {
            $0.path.localizedCaseInsensitiveCompare(folderPath) == .orderedSame
        }
    }

    private func folderDisplayName(for folderPath: String?) -> String {
        folderDefinition(for: folderPath)?.displayName ?? "My notes"
    }

    private func folderColor(for folderPath: String?) -> Color {
        folderColor(for: folderDefinition(for: folderPath)?.color ?? .gray)
    }

    private func folderColor(for color: NotesFolderColor) -> Color {
        switch color {
        case .gray:
            return Color.secondary
        case .orange:
            return .orange
        case .gold:
            return Color(red: 0.74, green: 0.61, blue: 0.23)
        case .purple:
            return Color(red: 0.58, green: 0.48, blue: 0.86)
        case .blue:
            return .blue
        case .teal:
            return .teal
        case .green:
            return .green
        case .red:
            return .red
        }
    }
}

private struct ComingUpDayGroupView: View {
    let group: UpcomingCalendarGrouping.DayGroup
    let showCalendarTitle: Bool
    let settings: AppSettings
    let sessionHistory: [SessionIndex]
    let earlierTodayEvents: [CalendarEvent]
    let showsEarlierToday: Bool
    let onToggleEarlierToday: () -> Void
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenRelatedNotes: (CalendarEvent) -> Void
    let onRequestMeetingFamilyFolderChange: (String?, CalendarEvent) -> Void
    let onCreateFolder: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.sectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                if !earlierTodayEvents.isEmpty {
                    earlierTodayDisclosure
                }

                ForEach(group.events) { event in
                    ComingUpEventRow(
                        event: event,
                        showJoinButton: true,
                        showCalendarTitle: showCalendarTitle,
                        settings: settings,
                        sessionHistory: sessionHistory,
                        onJoinEvent: onJoinEvent,
                        onOpenRelatedNotes: onOpenRelatedNotes,
                        onRequestMeetingFamilyFolderChange: onRequestMeetingFamilyFolderChange,
                        onCreateFolder: onCreateFolder
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var earlierTodayDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1)

                Button(action: onToggleEarlierToday) {
                    HStack(spacing: 5) {
                        Image(systemName: showsEarlierToday ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Earlier today")
                        Text("\(earlierTodayEvents.count)")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1)
            }

            if showsEarlierToday {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(earlierTodayEvents) { event in
                        ComingUpEventRow(
                            event: event,
                            showJoinButton: false,
                            showCalendarTitle: showCalendarTitle,
                            settings: settings,
                            sessionHistory: sessionHistory,
                            onJoinEvent: onJoinEvent,
                            onOpenRelatedNotes: onOpenRelatedNotes,
                            onRequestMeetingFamilyFolderChange: onRequestMeetingFamilyFolderChange,
                            onCreateFolder: onCreateFolder
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))

                if !group.events.isEmpty {
                    DashedSeparator()
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct DashedSeparator: View {
    var body: some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(Color.secondary.opacity(0.24))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

private struct ComingUpEventRow: View {
    let event: CalendarEvent
    let showJoinButton: Bool
    let showCalendarTitle: Bool
    let settings: AppSettings
    let sessionHistory: [SessionIndex]
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenRelatedNotes: (CalendarEvent) -> Void
    let onRequestMeetingFamilyFolderChange: (String?, CalendarEvent) -> Void
    let onCreateFolder: (CalendarEvent) -> Void

    @State private var isHovering = false
    @State private var isFolderHovering = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
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

            folderMenu

            if showJoinButton, event.meetingURL != nil {
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

    private var folderMenu: some View {
        let preferredFolderPath = settings.meetingFamilyPreferences(for: event)?.folderPath
        let choices = meetingFamilyFolderChoices(including: preferredFolderPath)

        return Menu {
            Button {
                onRequestMeetingFamilyFolderChange(nil, event)
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("My notes")
                    if preferredFolderPath == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !choices.isEmpty {
                Divider()
                ForEach(choices) { folder in
                    Button {
                        onRequestMeetingFamilyFolderChange(folder.path, event)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(folderColor(for: folder.color))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.displayName)
                                if let breadcrumb = folder.breadcrumb {
                                    Text(breadcrumb)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if preferredFolderPath?.localizedCaseInsensitiveCompare(folder.path) == .orderedSame {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                onCreateFolder(event)
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("New Folder…")
                }
            }
        } label: {
            HStack(spacing: 4) {
                folderGlyphBadge(for: preferredFolderPath)

                if isFolderHovering {
                    Text(folderDisplayName(for: preferredFolderPath))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, isFolderHovering ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFolderHovering ? Color.primary.opacity(0.05) : .clear)
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isFolderHovering = hovering
        }
        .help(folderHelpText(for: preferredFolderPath))
        .accessibilityIdentifier("idle.comingUp.folder.\(event.id)")
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

    private func folderHelpText(for preferredFolderPath: String?) -> String {
        let matchingHistoryCount = MeetingHistoryResolver.matchingSessions(
            forHistoryKey: settings.canonicalMeetingHistoryKey(for: event),
            sessionHistory: sessionHistory,
            aliases: settings.meetingHistoryAliasesByKey
        ).count
        let base = "Default folder: \(folderDisplayName(for: preferredFolderPath))"
        guard matchingHistoryCount > 0 else { return base }
        let noun = matchingHistoryCount == 1 ? "saved meeting" : "saved meetings"
        return "\(base). \(matchingHistoryCount) \(noun) already exist for this meeting family."
    }

    private func meetingFamilyFolderChoices(including preferredFolderPath: String?) -> [NotesFolderDefinition] {
        settings.notesFolders
            .filter {
                $0.path.split(separator: "/").count <= 2
                    || $0.path.localizedCaseInsensitiveCompare(preferredFolderPath ?? "") == .orderedSame
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func folderDefinition(for folderPath: String?) -> NotesFolderDefinition? {
        guard let folderPath else { return nil }
        return settings.notesFolders.first {
            $0.path.localizedCaseInsensitiveCompare(folderPath) == .orderedSame
        }
    }

    private func folderDisplayName(for folderPath: String?) -> String {
        folderDefinition(for: folderPath)?.displayName ?? "My notes"
    }

    private func folderColor(for folderPath: String?) -> Color {
        folderColor(for: folderDefinition(for: folderPath)?.color ?? .gray)
    }

    @ViewBuilder
    private func folderGlyphBadge(for folderPath: String?) -> some View {
        let color = folderColor(for: folderPath)

        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.14))
                .frame(width: 24, height: 24)

            Image(systemName: folderPath == nil ? "folder" : "folder.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private func folderColor(for color: NotesFolderColor) -> Color {
        switch color {
        case .gray:
            return Color.secondary
        case .orange:
            return .orange
        case .gold:
            return Color(red: 0.74, green: 0.61, blue: 0.23)
        case .purple:
            return Color(red: 0.58, green: 0.48, blue: 0.86)
        case .blue:
            return .blue
        case .teal:
            return .teal
        case .green:
            return .green
        case .red:
            return .red
        }
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

enum EarlierTodaySelection {
    static func select(
        from dayEvents: [CalendarEvent],
        now: Date,
        currentEventID: String?
    ) -> [CalendarEvent] {
        dayEvents
            .filter { event in
                event.endDate <= now && event.id != currentEventID
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate > rhs.startDate
                }
                return lhs.id > rhs.id
            }
    }
}

enum ComingUpDayGroupSelection {
    static func groups(
        for upcomingEvents: [CalendarEvent],
        earlierTodayEvents: [CalendarEvent],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [UpcomingCalendarGrouping.DayGroup] {
        var groups = UpcomingCalendarGrouping.groups(for: upcomingEvents, calendar: calendar)
        guard !earlierTodayEvents.isEmpty else { return groups }

        let today = calendar.startOfDay(for: referenceDate)
        let hasTodayGroup = groups.contains { calendar.isDate($0.date, inSameDayAs: today) }
        guard !hasTodayGroup else { return groups }

        groups.insert(
            UpcomingCalendarGrouping.DayGroup(date: today, events: []),
            at: 0
        )
        return groups
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
