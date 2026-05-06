import AppKit
import SwiftUI

struct HomeTimelineWorkspaceView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator

    @State private var notesController: NotesController?
    @State private var calendarEvents: [CalendarEvent] = []
    @State private var refreshTick = 0
    @State private var selectedEntryID: String?
    @State private var detailViewMode: MeetingDetailViewMode = .notes
    @State private var showingAddTranscriptSheet = false
    @State private var manualTranscriptDraft = ""
    @State private var creatingFolderForSessionID: String?
    @State private var newFolderPath = ""
    @State private var newFolderColor: NotesFolderColor = .orange
    @FocusState private var newFolderFieldFocused: Bool

    var body: some View {
        let accessState = currentAccessState

        Group {
            if let controller = notesController {
                workspace(controller: controller, accessState: accessState)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
        .task {
            if coordinator.knowledgeBase == nil {
                container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
            }
            let controller = NotesController(coordinator: coordinator, settings: settings)
            notesController = controller
            await container.seedIfNeeded(coordinator: coordinator)
            await coordinator.loadHistory()
            await controller.loadHistory()
        }
        .task(id: refreshTaskID(for: accessState)) {
            await refreshCalendarEvents()
            guard settings.calendarIntegrationEnabled else { return }
            try? await Task.sleep(for: refreshInterval(for: accessState))
            refreshTick &+= 1
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            refreshTick &+= 1
        }
        .onChange(of: coordinator.sessionHistory.count) {
            Task { await notesController?.loadHistory() }
        }
        .onChange(of: coordinator.batchStatus) { _, newStatus in
            if case .completed = newStatus {
                Task { await notesController?.loadHistory() }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { creatingFolderForSessionID != nil },
                set: { if !$0 { cancelCreateFolder() } }
            )
        ) {
            if let sessionID = creatingFolderForSessionID, let controller = notesController {
                newFolderSheet(controller: controller, sessionID: sessionID)
            }
        }
    }

    @ViewBuilder
    private func workspace(controller: NotesController, accessState: CalendarManager.AccessState) -> some View {
        let groups = HomeTimelineGrouping.groups(
            calendarEvents: calendarEvents,
            savedSessions: controller.state.sessionHistory
        )
        let isDetailVisible = selectedEntryID != nil

        HStack(spacing: 0) {
            timelinePane(
                controller: controller,
                groups: groups,
                accessState: accessState,
                isDetailVisible: isDetailVisible
            )
            .frame(minWidth: 340, idealWidth: isDetailVisible ? 360 : 520, maxWidth: isDetailVisible ? 390 : .infinity)

            if isDetailVisible {
                Divider()

                detailPane(controller: controller)
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: isDetailVisible)
    }

    @ViewBuilder
    private func timelinePane(
        controller: NotesController,
        groups: [HomeTimelineDayGroup],
        accessState: CalendarManager.AccessState,
        isDetailVisible: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meetings")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Upcoming and saved history")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    collapseDetail(controller: controller)
                    refreshTick &+= 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityIdentifier("home.timeline.refresh")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    calendarAccessNotice(accessState: accessState, hasCalendarEntries: !calendarEvents.isEmpty)

                    if groups.isEmpty {
                        emptyTimeline(accessState: accessState)
                    } else {
                        ForEach(groups) { group in
                            HomeTimelineDayGroupView(
                                group: group,
                                selectedEntryID: selectedEntryID,
                                showCalendarTitle: UpcomingEventSelection.distinctCalendarCount(in: calendarEvents) > 1,
                                settings: settings,
                                sessionHistory: controller.state.sessionHistory,
                                onSelect: { entry in
                                    select(entry, controller: controller)
                                },
                                onJoinEvent: joinMeeting(for:)
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityIdentifier("home.timeline")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func detailPane(controller: NotesController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    collapseDetail(controller: controller)
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back to timeline")
                .accessibilityIdentifier("home.detail.close")

                Text("Meeting detail")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home.detailPane")

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            MeetingDetailPane(
                settings: settings,
                controller: controller,
                state: controller.state,
                detailViewMode: $detailViewMode,
                isAddTranscriptPresented: $showingAddTranscriptSheet,
                manualTranscriptDraft: $manualTranscriptDraft
            ) { session in
                sessionFolderAssignmentMenu(controller: controller, session: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.48))
    }

    @ViewBuilder
    private func calendarAccessNotice(
        accessState: CalendarManager.AccessState,
        hasCalendarEntries: Bool
    ) -> some View {
        if !settings.calendarIntegrationEnabled {
            HomeTimelineNotice(
                icon: "calendar.badge.exclamationmark",
                title: "Calendar integration is off",
                message: "Saved meetings are still available here.",
                actionTitle: "Open Settings",
                action: nil
            )
        } else if accessState == .denied {
            HomeTimelineNotice(
                icon: "exclamationmark.triangle.fill",
                title: "Calendar access denied",
                message: hasCalendarEntries ? "" : "Grant Calendar access to include upcoming meetings.",
                actionTitle: "Open Privacy Settings",
                action: openCalendarPrivacySettings
            )
        } else if accessState == .notDetermined {
            HomeTimelineNotice(
                icon: "calendar",
                title: "Waiting for calendar access",
                message: "Saved meetings are still available while OpenOats waits for Calendar access.",
                actionTitle: nil,
                action: nil
            )
        }
    }

    private func emptyTimeline(accessState: CalendarManager.AccessState) -> some View {
        let copy = emptyTimelineCopy(accessState: accessState)

        return ContentUnavailableView {
            Label(copy.title, systemImage: "calendar")
        } description: {
            Text(copy.description)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func emptyTimelineCopy(accessState: CalendarManager.AccessState) -> (title: String, description: String) {
        if !settings.calendarIntegrationEnabled {
            return (
                "No saved meetings yet",
                "Recorded meetings will appear here even while Calendar integration is off."
            )
        }
        if accessState == .authorized {
            return (
                "No meetings yet",
                "Upcoming calendar meetings and saved history will appear here."
            )
        }
        return (
            "No saved meetings yet",
            "Saved meetings will appear here even before Calendar access is available."
        )
    }

    private func select(_ entry: HomeTimelineEntry, controller: NotesController) {
        selectedEntryID = entry.id
        switch entry {
        case .calendar(let event):
            controller.showMeetingFamily(for: event)
            detailViewMode = .notes
        case .savedSession(let session):
            controller.selectSession(session.id)
            detailViewMode = session.hasNotes ? .notes : .transcript
        }
        resizeMainWindow(detailVisible: true)
    }

    private func collapseDetail(controller: NotesController) {
        selectedEntryID = nil
        controller.selectSession(nil)
        resizeMainWindow(detailVisible: false)
    }

    @MainActor
    private func refreshCalendarEvents() async {
        guard settings.calendarIntegrationEnabled, let manager = container.calendarManager else {
            calendarEvents = []
            return
        }

        manager.refreshFromSystem()

        guard manager.accessState == .authorized else {
            calendarEvents = []
            return
        }

        let now = Date()
        let currentEvent = manager.currentEvent(
            at: now,
            excludingCalendarIDs: settings.excludedCalendarIDs
        )
        let upcomingEvents = manager.upcomingEvents(
            from: now,
            within: 7 * 24 * 60 * 60,
            limit: 24,
            excludingCalendarIDs: settings.excludedCalendarIDs
        )

        var combined: [CalendarEvent] = []
        if let currentEvent {
            combined.append(currentEvent)
        }

        let remainingLimit = max(0, 24 - combined.count)
        combined.append(
            contentsOf: UpcomingEventSelection.select(
                from: upcomingEvents.filter { $0.id != currentEvent?.id },
                limit: remainingLimit
            )
        )
        calendarEvents = combined
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

    private func joinMeeting(for event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        _ = NSWorkspace.shared.open(url)
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

    private func resizeMainWindow(detailVisible: Bool) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) else {
            return
        }

        let targetWidth: CGFloat = detailVisible ? 980 : 520
        let currentFrame = window.frame
        let newWidth = detailVisible ? max(currentFrame.width, targetWidth) : min(currentFrame.width, targetWidth)
        guard abs(newWidth - currentFrame.width) > 8 else { return }

        var frame = currentFrame
        frame.origin.x -= max(0, newWidth - currentFrame.width)
        frame.size.width = newWidth
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Session Folders

    @ViewBuilder
    private func sessionFolderAssignmentMenu(controller: NotesController, session: SessionIndex) -> some View {
        Button {
            controller.updateSessionFolder(sessionID: session.id, folderPath: nil)
        } label: {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("My notes")
                if session.folderPath == nil {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }

        if !settings.notesFolders.isEmpty {
            Divider()
            ForEach(settings.notesFolders) { folder in
                Button {
                    controller.updateSessionFolder(sessionID: session.id, folderPath: folder.path)
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
                        if session.folderPath == folder.path {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            beginCreateFolder(for: session)
        } label: {
            HStack {
                Image(systemName: "folder.badge.plus")
                Text("New Folder...")
            }
        }
    }

    private func beginCreateFolder(for session: SessionIndex) {
        newFolderPath = session.folderPath ?? ""
        newFolderColor = folderDefinition(for: session.folderPath)?.color ?? .orange
        creatingFolderForSessionID = session.id
    }

    @ViewBuilder
    private func newFolderSheet(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder")
                .font(.headline)

            Text("Use a folder path like `Work` or `Work/1:1s`.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("e.g. Work/1:1s", text: $newFolderPath)
                .textFieldStyle(.roundedBorder)
                .focused($newFolderFieldFocused)
                .onAppear {
                    newFolderFieldFocused = true
                }
                .onSubmit {
                    commitCreateFolder(controller: controller, sessionID: sessionID)
                }

            folderColorGrid(selectedColor: $newFolderColor)

            HStack {
                Spacer()

                Button("Cancel") {
                    cancelCreateFolder()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    commitCreateFolder(controller: controller, sessionID: sessionID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(NotesFolderDefinition.normalizePath(newFolderPath) == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
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

    private func commitCreateFolder(controller: NotesController, sessionID: String) {
        guard let normalizedPath = NotesFolderDefinition.normalizePath(newFolderPath) else { return }
        var folders = settings.notesFolders
        if let existingIndex = folders.firstIndex(where: { $0.path.caseInsensitiveCompare(normalizedPath) == .orderedSame }) {
            folders[existingIndex].color = newFolderColor
        } else {
            folders.append(NotesFolderDefinition(path: normalizedPath, color: newFolderColor))
        }
        settings.notesFolders = folders
        controller.updateSessionFolder(sessionID: sessionID, folderPath: normalizedPath)
        cancelCreateFolder()
    }

    private func cancelCreateFolder() {
        creatingFolderForSessionID = nil
        newFolderPath = ""
        newFolderColor = .orange
        newFolderFieldFocused = false
    }

    private func folderDefinition(for folderPath: String?) -> NotesFolderDefinition? {
        guard let folderPath else { return nil }
        return settings.notesFolders.first {
            $0.path.localizedCaseInsensitiveCompare(folderPath) == .orderedSame
        }
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

private struct HomeTimelineDayGroupView: View {
    let group: HomeTimelineDayGroup
    let selectedEntryID: String?
    let showCalendarTitle: Bool
    let settings: AppSettings
    let sessionHistory: [SessionIndex]
    let onSelect: (HomeTimelineEntry) -> Void
    let onJoinEvent: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.sectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 6)

            VStack(spacing: 4) {
                ForEach(group.entries) { entry in
                    HomeTimelineEntryRow(
                        entry: entry,
                        isSelected: selectedEntryID == entry.id,
                        showCalendarTitle: showCalendarTitle,
                        settings: settings,
                        sessionHistory: sessionHistory,
                        onSelect: { onSelect(entry) },
                        onJoinEvent: onJoinEvent
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeTimelineEntryRow: View {
    let entry: HomeTimelineEntry
    let isSelected: Bool
    let showCalendarTitle: Bool
    let settings: AppSettings
    let sessionHistory: [SessionIndex]
    let onSelect: () -> Void
    let onJoinEvent: (CalendarEvent) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    leadingMarker

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(rowBackground)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }
            .accessibilityIdentifier(accessibilityIdentifier)

            if case .calendar(let event) = entry, event.meetingURL != nil {
                Button {
                    onJoinEvent(event)
                } label: {
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
                .accessibilityIdentifier("home.timeline.join.\(event.id)")
            }
        }
    }

    @ViewBuilder
    private var leadingMarker: some View {
        switch entry {
        case .calendar(let event):
            RoundedRectangle(cornerRadius: 2)
                .fill(calendarColor(for: event))
                .frame(width: 4, height: 44)
        case .savedSession:
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovering ? Color.primary.opacity(0.05) : .clear))
    }

    private var title: String {
        switch entry {
        case .calendar(let event):
            return event.title
        case .savedSession(let session):
            return nonBlank(session.title) ?? "Untitled"
        }
    }

    private var subtitle: String {
        switch entry {
        case .calendar(let event):
            let time = CalendarEventDisplay.timeRange(for: event)
            guard showCalendarTitle,
                  let calendarTitle = event.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !calendarTitle.isEmpty else {
                return time
            }
            return "\(time)  -  \(calendarTitle)"
        case .savedSession(let session):
            return session.startedAt.formatted(.dateTime.hour().minute())
        }
    }

    private var statusText: String {
        switch entry {
        case .calendar(let event):
            return UpcomingMeetingReadiness.resolve(
                for: event,
                settings: settings,
                sessionHistory: sessionHistory
            ).summaryText
        case .savedSession(let session):
            if session.hasNotes {
                return "Notes saved"
            }
            return session.notesTranscriptStatusText
        }
    }

    private var accessibilityIdentifier: String {
        switch entry {
        case .calendar(let event):
            return "home.timeline.calendar.\(event.id)"
        case .savedSession(let session):
            return "home.timeline.session.\(session.id)"
        }
    }

    private func calendarColor(for event: CalendarEvent) -> Color {
        guard let hex = event.calendarColorHex,
              let color = CalendarColorCodec.color(from: hex) else {
            return .accentColor
        }
        return color
    }

    private func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct HomeTimelineNotice: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else if let actionTitle {
                SettingsLink {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
