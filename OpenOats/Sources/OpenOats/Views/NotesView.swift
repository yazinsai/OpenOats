import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var notesController: NotesController?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var creatingFolderForSessionID: String?
    @State private var newFolderPath: String = ""
    @State private var newFolderColor: NotesFolderColor = .orange
    @FocusState private var newFolderFieldFocused: Bool
    @State private var sessionToDelete: String?
    @State private var showDeleteConfirmation = false
    @State private var bulkDeleteMode = false
    @State private var bulkDeleteSelection: Set<String> = []
    @State private var showBulkDeleteConfirmation = false
    @State private var editingTagsSessionID: String?
    @State private var editingTags: [String] = []
    @State private var newTagText: String = ""
    @State private var availableTags: [String] = []

    enum DetailViewMode: String, CaseIterable {
        case transcript = "Transcript"
        case notes = "Notes"
    }

    enum MeetingFamilyBottomTab: String, CaseIterable {
        case history = "Previous meetings"
        case link = "Link meetings"
    }

    @State private var detailViewMode: DetailViewMode = .transcript
    @State private var meetingFamilyBottomTab: MeetingFamilyBottomTab = .history
    @State private var isMeetingFamilyBottomCollapsed = false

    var body: some View {
        Group {
            if let controller = notesController {
                mainContent(controller: controller)
            } else {
                ProgressView()
            }
        }
        .task {
            let controller = NotesController(coordinator: coordinator, settings: settings)
            notesController = controller
            await controller.loadHistory()

            // Handle pending navigation — inline rather than via controller
            // to ensure @State detailViewMode update happens in the same
            // transaction as session selection (matches pre-Phase 6 behavior).
            if let requested = coordinator.consumeRequestedSessionSelection() {
                switch requested {
                case .session(let sessionID):
                    controller.selectSession(sessionID)
                    // Show Transcript tab for imported sessions (no notes generated yet)
                    let isImported = controller.state.sessionHistory.first(where: { $0.id == sessionID })?.source == "imported"
                    detailViewMode = isImported ? .transcript : .notes
                case .meetingHistory(let event):
                    controller.showMeetingFamily(for: event)
                    detailViewMode = .notes
                case .clearSelection:
                    controller.selectSession(nil)
                    detailViewMode = .notes
                }
            } else if let last = coordinator.lastEndedSession {
                controller.selectSession(last.id)
            }
        }
    }

    @ViewBuilder
    private func mainContent(controller: NotesController) -> some View {
        let state = controller.state
        HStack(spacing: 0) {
            sidebar(controller: controller, state: state)
                .frame(width: 250)
            Divider()
            detailContent(controller: controller, state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            Task { await controller.handleLastEndedSessionChanged() }
        }
        .onChange(of: coordinator.sessionHistory.count) {
            Task { await controller.loadHistory() }
        }
        .onChange(of: coordinator.requestedNotesNavigation?.id) {
            if controller.handleRequestedSessionSelection() {
                detailViewMode = .notes
            }
        }
        .onChange(of: state.selectedMeetingFamily?.key) {
            meetingFamilyBottomTab = .history
            isMeetingFamilyBottomCollapsed = false
        }
        .sheet(
            isPresented: Binding(
                get: { renamingSessionID != nil },
                set: { if !$0 { cancelRename() } }
            )
        ) {
            if let sessionID = renamingSessionID {
                renameSessionSheet(controller: controller, sessionID: sessionID)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { creatingFolderForSessionID != nil },
                set: { if !$0 { cancelCreateFolder() } }
            )
        ) {
            if let sessionID = creatingFolderForSessionID {
                newFolderSheet(controller: controller, sessionID: sessionID)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func sidebar(controller: NotesController, state: NotesState) -> some View {
        VStack(spacing: 0) {
            tagFilterBar(controller: controller, state: state)

            // Bulk delete toolbar
            if bulkDeleteMode {
                HStack(spacing: 8) {
                    Button("Select All") {
                        bulkDeleteSelection = Set(controller.filteredSessions.map(\.id))
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    if !bulkDeleteSelection.isEmpty {
                        Button("Delete \(bulkDeleteSelection.count)") {
                            showBulkDeleteConfirmation = true
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    Button("Done") {
                        bulkDeleteMode = false
                        bulkDeleteSelection = []
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            if bulkDeleteMode {
                List(selection: $bulkDeleteSelection) {
                    if controller.showsFolderSections {
                        if !controller.rootFolderSessions.isEmpty {
                            Section {
                                ForEach(controller.rootFolderSessions) { session in
                                    sessionRow(controller: controller, session: session)
                                }
                            } header: {
                                rootFolderSectionHeader()
                            }
                        }
                        ForEach(controller.folderGroups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    sessionRow(controller: controller, session: session)
                                }
                            } header: {
                                folderSectionHeader(group)
                            }
                        }
                    } else if controller.showsSourceSections {
                        ForEach(controller.sessionSourceGroups) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { session in
                                    sessionRow(controller: controller, session: session)
                                }
                            }
                        }
                    } else {
                        ForEach(controller.filteredSessions) { session in
                            sessionRow(controller: controller, session: session)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                let selectedBinding = Binding<String?>(
                    get: { state.selectedSessionID },
                    set: { controller.selectSession($0) }
                )
                List(selection: selectedBinding) {
                    if controller.showsFolderSections {
                        if !controller.rootFolderSessions.isEmpty {
                            Section {
                                ForEach(controller.rootFolderSessions) { session in
                                    sessionListEntry(controller: controller, session: session)
                                }
                            } header: {
                                rootFolderSectionHeader()
                            }
                        }
                        ForEach(controller.folderGroups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    sessionListEntry(controller: controller, session: session)
                                }
                            } header: {
                                folderSectionHeader(group)
                            }
                        }
                    } else if controller.showsSourceSections {
                        ForEach(controller.sessionSourceGroups) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { session in
                                    sessionListEntry(controller: controller, session: session)
                                }
                            }
                        }
                    } else {
                        ForEach(controller.filteredSessions) { session in
                            sessionListEntry(controller: controller, session: session)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(maxHeight: .infinity)
        .alert("Delete Meeting?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = sessionToDelete {
                    controller.deleteSession(sessionID: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the transcript and any generated notes.")
        }
        .alert("Delete \(bulkDeleteSelection.count) Meetings?", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete \(bulkDeleteSelection.count)", role: .destructive) {
                controller.deleteSessions(sessionIDs: bulkDeleteSelection)
                bulkDeleteMode = false
                bulkDeleteSelection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected transcripts and any generated notes.")
        }
    }

    @ViewBuilder
    private func sessionListEntry(controller: NotesController, session: SessionIndex) -> some View {
        sessionRow(controller: controller, session: session)
            .contextMenu {
                sessionContextMenu(controller: controller, session: session)
            }
            .popover(isPresented: Binding(
                get: { editingTagsSessionID == session.id },
                set: { if !$0 { editingTagsSessionID = nil } }
            )) {
                tagEditorPopover(controller: controller, sessionID: session.id)
            }
    }

    @ViewBuilder
    private func sessionContextMenu(controller: NotesController, session: SessionIndex) -> some View {
        Button("Rename...") {
            beginRenaming(session)
        }
        Menu("Move to Folder") {
            folderAssignmentMenu(controller: controller, session: session)
        }
        Button("Edit Tags...") {
            editingTags = NotesController.visibleTags(for: session)
            newTagText = ""
            editingTagsSessionID = session.id
            Task {
                availableTags = await controller.allTags()
            }
        }
        Divider()
        Button("Select Multiple...") {
            bulkDeleteMode = true
            bulkDeleteSelection = [session.id]
        }
        Divider()
        Button("Delete", role: .destructive) {
            sessionToDelete = session.id
            showDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private func sessionRow(controller: NotesController, session: SessionIndex) -> some View {
        let visibleTags = NotesController.visibleTags(for: session)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let snap = session.templateSnapshot {
                    Image(systemName: snap.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(sessionTitle(for: session))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("notes.sessionTitle.\(session.id)")
                Spacer()
                if controller.isGenerating(sessionID: session.id) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else if session.hasNotes {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(
                            controller.state.freshlyGeneratedSessionIDs.contains(session.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                }
                Menu {
                    folderAssignmentMenu(controller: controller, session: session)
                } label: {
                    Image(systemName: session.folderPath == nil ? "folder" : "folder.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(folderColor(for: session.folderPath))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help(session.folderPath.map { "Folder: \($0)" } ?? "Assign folder")
            }

            HStack(spacing: 6) {
                Text(session.startedAt, style: .date)
                Text(session.startedAt, style: .time)
                Spacer()
                Text("\(session.utteranceCount) utterances")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            if !visibleTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(visibleTags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("notes.session.\(session.id)")
    }

    @ViewBuilder
    private func renameSessionSheet(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Meeting")
                .font(.headline)

            TextField(renamePlaceholder(for: sessionID, controller: controller), text: $renameText)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .accessibilityIdentifier("notes.renameSheet.field")
                .onAppear {
                    renameFieldFocused = true
                }
                .onSubmit {
                    commitRename(controller: controller, sessionID: sessionID)
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    cancelRename()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    commitRename(controller: controller, sessionID: sessionID)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("notes.renameSheet.saveButton")
            }
        }
        .padding(20)
        .frame(width: 360)
        .accessibilityIdentifier("notes.renameSheet")
    }

    private func beginRenaming(_ session: SessionIndex) {
        renameText = session.title ?? ""
        renamingSessionID = session.id
    }

    private func commitRename(controller: NotesController, sessionID: String) {
        let trimmedTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.renameSession(sessionID: sessionID, newTitle: trimmedTitle)
        cancelRename()
    }

    private func cancelRename() {
        renamingSessionID = nil
        renameFieldFocused = false
        renameText = ""
    }

    @ViewBuilder
    private func newFolderSheet(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder")
                .font(.headline)

            Text("Use `/` to create subfolders inside your Notes list.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("e.g. Work/1:1s", text: $newFolderPath)
                .textFieldStyle(.roundedBorder)
                .focused($newFolderFieldFocused)
                .accessibilityIdentifier("notes.newFolderSheet.field")
                .onAppear {
                    newFolderFieldFocused = true
                }
                .onSubmit {
                    commitCreateFolder(controller: controller, sessionID: sessionID)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.system(size: 12, weight: .medium))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 4), spacing: 8) {
                    ForEach(NotesFolderColor.allCases) { color in
                        Button {
                            newFolderColor = color
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(folderColor(for: color))
                                    .frame(width: 18, height: 18)
                                if newFolderColor == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .stroke(
                                        newFolderColor == color ? Color.primary.opacity(0.35) : Color.secondary.opacity(0.15),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(color.displayName)
                    }
                }
            }

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
                .accessibilityIdentifier("notes.newFolderSheet.saveButton")
            }
        }
        .padding(20)
        .frame(width: 360)
        .accessibilityIdentifier("notes.newFolderSheet")
    }

    @ViewBuilder
    private func folderAssignmentMenu(controller: NotesController, session: SessionIndex) -> some View {
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
                Text("New Folder…")
            }
        }
    }

    private func beginCreateFolder(for session: SessionIndex) {
        newFolderPath = session.folderPath ?? ""
        newFolderColor = folderDefinition(for: session.folderPath)?.color ?? .orange
        creatingFolderForSessionID = session.id
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
        newFolderFieldFocused = false
        newFolderPath = ""
        newFolderColor = .orange
    }

    private func sessionTitle(for session: SessionIndex) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil) ?? "Untitled"
    }

    @ViewBuilder
    private func folderSectionHeader(_ group: SessionFolderGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(folderColor(for: group.id))
            Text(group.title)
        }
    }

    @ViewBuilder
    private func rootFolderSectionHeader() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("My notes")
        }
    }

    private func renamePlaceholder(for sessionID: String, controller: NotesController) -> String {
        let title = controller.state.sessionHistory
            .first(where: { $0.id == sessionID })?
            .title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil) ?? "Untitled"
    }

    // MARK: - Tag Filter Bar

    @ViewBuilder
    private func tagFilterBar(controller: NotesController, state: NotesState) -> some View {
        let allTags = uniqueTags(from: state.sessionHistory)
        if !allTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allTags, id: \.self) { tag in
                        let isActive = state.tagFilter?.localizedCaseInsensitiveCompare(tag) == .orderedSame
                        Button {
                            controller.setTagFilter(isActive ? nil : tag)
                        } label: {
                            Text(tag)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    private func uniqueTags(from sessions: [SessionIndex]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in sessions {
            for tag in NotesController.visibleTags(for: session) {
                let key = tag.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(tag)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    // MARK: - Tag Editor Popover

    @ViewBuilder
    private func tagEditorPopover(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags")
                .font(.headline)

            // Current tags as removable chips
            if !editingTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(editingTags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag)
                                .font(.system(size: 12))
                            Button {
                                editingTags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                                controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                    }
                }
            }

            if editingTags.count < 5 {
                HStack(spacing: 6) {
                    TextField("Add tag...", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            commitNewTag(controller: controller, sessionID: sessionID)
                        }
                    Button("Add") {
                        commitNewTag(controller: controller, sessionID: sessionID)
                    }
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Autocomplete suggestions
                let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let suggestions = availableTags.filter { suggestion in
                    guard !trimmed.isEmpty else { return false }
                    let lower = suggestion.lowercased()
                    return lower.contains(trimmed) && !editingTags.contains(where: { $0.localizedCaseInsensitiveCompare(suggestion) == .orderedSame })
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                            Button {
                                editingTags.append(suggestion)
                                newTagText = ""
                                controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } else {
                Text("Maximum 5 tags per session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func commitNewTag(controller: NotesController, sessionID: String) {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !editingTags.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            newTagText = ""
            return
        }
        guard editingTags.count < 5 else { return }
        editingTags.append(trimmed)
        newTagText = ""
        controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailContent(controller: NotesController, state: NotesState) -> some View {
        if let selection = state.selectedMeetingFamily {
            meetingFamilyDetail(controller: controller, state: state, selection: selection)
        } else {
            ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text("Choose a session from the sidebar to view or generate notes."))
        }
    }

    @ViewBuilder
    private func meetingFamilyDetail(
        controller: NotesController,
        state: NotesState,
        selection: MeetingFamilySelection
    ) -> some View {
        let focusedSessionID = state.selectedSessionID
        let historyEntries = state.meetingHistoryEntries.filter { $0.session.id != focusedSessionID }
        let suggestions = state.relatedMeetingSuggestions
        let hasHistory = !historyEntries.isEmpty
        let hasSuggestions = !suggestions.isEmpty
        let showsTabs = hasHistory && hasSuggestions
        let activeBottomTab: MeetingFamilyBottomTab = showsTabs
            ? meetingFamilyBottomTab
            : (hasHistory ? .history : .link)
        let bottomSectionLabel = hasHistory ? "Previous meetings" : "Related meetings"

        GeometryReader { proxy in
            let totalHeight = proxy.size.height
            let showsBottomSection = hasHistory || hasSuggestions
            let bottomHeight = defaultMeetingFamilyBottomHeight(
                totalHeight: totalHeight,
                focusedSessionID: focusedSessionID
            )

            VStack(spacing: 0) {
                if focusedSessionID != nil {
                    focusedSessionDetail(controller: controller, state: state, selection: selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            meetingFamilyOverviewSection(selection: selection, historyCount: state.meetingHistoryEntries.count)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showsBottomSection {
                    meetingFamilyCollapseHandle(title: bottomSectionLabel)

                    if !isMeetingFamilyBottomCollapsed {
                        meetingFamilyBottomSection(
                            controller: controller,
                            historyEntries: historyEntries,
                            suggestions: suggestions,
                            activeTab: activeBottomTab,
                            showsTabs: showsTabs,
                            linkingSuggestionKey: state.linkingMeetingSuggestionKey
                        )
                        .frame(maxWidth: .infinity, minHeight: bottomHeight, maxHeight: bottomHeight)
                    }
                } else if focusedSessionID == nil {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        description: Text("OpenOats hasn’t saved any other meetings for this title yet.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func defaultMeetingFamilyBottomHeight(totalHeight: CGFloat, focusedSessionID: String?) -> CGFloat {
        let preferred = focusedSessionID != nil ? min(300, totalHeight * 0.42) : min(340, totalHeight * 0.45)
        return max(preferred, 120)
    }

    @ViewBuilder
    private func meetingFamilyCollapseHandle(title: String) -> some View {
        ZStack {
            Divider()

            Button {
                withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                    isMeetingFamilyBottomCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isMeetingFamilyBottomCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isMeetingFamilyBottomCollapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
        }
        .frame(height: 18)
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    @ViewBuilder
    private func meetingFamilyBottomSection(
        controller: NotesController,
        historyEntries: [MeetingHistoryEntry],
        suggestions: [MeetingHistorySuggestion],
        activeTab: MeetingFamilyBottomTab,
        showsTabs: Bool,
        linkingSuggestionKey: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTabs {
                meetingFamilyBottomTabBar
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }

            switch activeTab {
            case .history:
                meetingHistorySection(
                    controller: controller,
                    historyEntries: historyEntries,
                    showsHeader: !showsTabs
                )
            case .link:
                relatedMeetingSuggestionsSection(
                    controller: controller,
                    suggestions: suggestions,
                    showsExistingHistory: !historyEntries.isEmpty,
                    linkingSuggestionKey: linkingSuggestionKey,
                    showsHeader: !showsTabs
                )
            }
        }
    }

    @ViewBuilder
    private var meetingFamilyBottomTabBar: some View {
        HStack(spacing: 6) {
            meetingFamilyBottomTabButton(title: "Previous meetings", tab: .history)
            meetingFamilyBottomTabButton(title: "Link meetings", tab: .link)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func meetingFamilyBottomTabButton(
        title: String,
        tab: MeetingFamilyBottomTab
    ) -> some View {
        let isSelected = meetingFamilyBottomTab == tab
        Button {
            meetingFamilyBottomTab = tab
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(
                            isSelected ? Color.primary.opacity(0.06) : Color.clear,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isSelected ? Color.black.opacity(0.06) : .clear,
                    radius: 6,
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func meetingFamilyOverviewSection(selection: MeetingFamilySelection, historyCount: Int) -> some View {
        if let event = selection.upcomingEvent {
            let prepNotes = Binding(
                get: { settings.meetingPrepNotes(for: event) },
                set: { settings.setMeetingPrepNotes($0, for: event) }
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.primary)

                        HStack(spacing: 12) {
                            Text(CalendarEventDisplay.timeRange(for: event))
                            if let calendarTitle = event.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !calendarTitle.isEmpty {
                                Text("Calendar: \(calendarTitle)")
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        if event.meetingURL != nil {
                            Button {
                                joinMeeting(for: event)
                            } label: {
                                Label("Join", systemImage: "video.fill")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }

                        Button {
                            startRecording(for: event)
                        } label: {
                            Label("Start recording", systemImage: "mic.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.isRecording)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Prep notes")
                            .font(.system(size: 12, weight: .medium))
                        if !prepNotes.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                    }

                    TextEditor(text: prepNotes)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(selection.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 12) {
                    Text("Meeting history")
                    Text("\(historyCount) saved meeting\(historyCount == 1 ? "" : "s")")
                    if let calendarTitle = selection.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !calendarTitle.isEmpty {
                        Text("Calendar: \(calendarTitle)")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func focusedSessionDetail(controller: NotesController, state: NotesState, selection: MeetingFamilySelection) -> some View {
        VStack(spacing: 0) {
            detailToolbar(controller: controller, state: state)
            Divider()
            meetingFamilyHeaderStrip(state: state, selection: selection, controller: controller)
            Divider()
            if let calendarEvent = state.loadedCalendarEvent {
                notesCalendarContextStrip(calendarEvent)
                Divider()
            }
            if let sessionID = state.selectedSessionID {
                detailBody(controller: controller, state: state, sessionID: sessionID)
            }
        }
        .background {
            Group {
                Button("") { detailViewMode = .transcript }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { detailViewMode = .notes }
                    .keyboardShortcut("2", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func meetingFamilyHeaderStrip(
        state: NotesState,
        selection: MeetingFamilySelection,
        controller: NotesController
    ) -> some View {
        let hasCalendarContext = state.loadedCalendarEvent != nil

        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.showCurrentMeetingFamilyOverview()
                detailViewMode = .notes
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.borderless)
            .help("Back")

            if hasCalendarContext {
                Text("Meeting history")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let sessionID = state.selectedSessionID,
                           let session = state.sessionHistory.first(where: { $0.id == sessionID }) {
                            Text(session.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        }

                        if let calendarTitle = selection.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !calendarTitle.isEmpty {
                            Text("Calendar: \(calendarTitle)")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func meetingHistorySection(
        controller: NotesController,
        historyEntries: [MeetingHistoryEntry],
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                Text("Previous meetings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(historyEntries) { entry in
                        Button {
                            openSessionFromMeetingHistory(entry.session, controller: controller)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(entry.session.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)

                                    if entry.session.hasNotes {
                                        Image(systemName: "doc.text.fill")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }

                                    if entry.session.folderPath != nil {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(folderColor(for: entry.session.folderPath))
                                    }
                                }

                                HStack(spacing: 8) {
                                    if entry.session.utteranceCount > 0 {
                                        Text("\(entry.session.utteranceCount) utterances")
                                    } else {
                                        Text("No transcript")
                                    }

                                    if let source = entry.session.source?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !source.isEmpty {
                                        Text("•")
                                        Text(source.capitalized)
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                                if let preview = entry.notesPreview {
                                    Text(preview)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .help("Open this meeting")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func openSessionFromMeetingHistory(_ session: SessionIndex, controller: NotesController) {
        controller.selectSession(session.id)
        detailViewMode = session.hasNotes ? .notes : .transcript
    }

    private func startRecording(for event: CalendarEvent) {
        let prepNotes = settings.meetingPrepNotes(for: event)
        coordinator.queueExternalCommand(
            .startSession(
                calendarEvent: event,
                scratchpadSeed: prepNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prepNotes
            )
        )
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: OpenOatsRootApp.mainWindowID)
    }

    private func joinMeeting(for event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private enum CleanupState {
        case notCleaned
        case inProgress
        case partiallyCleaned
        case cleaned
    }

    private func cleanupState(from status: CleanupStatus, transcript: [SessionRecord]) -> CleanupState {
        if case .inProgress = status { return .inProgress }
        guard !transcript.isEmpty else { return .notCleaned }
        let hasAnyCleaned = transcript.contains(where: { $0.cleanedText != nil })
        if !hasAnyCleaned { return .notCleaned }
        let allCleaned = !transcript.contains(where: { $0.cleanedText == nil })
        return allCleaned ? .cleaned : .partiallyCleaned
    }

    @ViewBuilder
    private func detailToolbar(controller: NotesController, state: NotesState) -> some View {
        HStack(spacing: 8) {
            Picker("View", selection: $detailViewMode) {
                ForEach(DetailViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 120, maxWidth: 220)
            .layoutPriority(1)

            Spacer(minLength: 4)

            if detailViewMode == .transcript {
                transcriptToolbarActions(controller: controller, state: state)
            } else if detailViewMode == .notes {
                notesToolbarActions(controller: controller, state: state)
            }

            if state.audioFileURL != nil {
                audioPlaybackButton(controller: controller, state: state)
            }

            Button {
                copyCurrentContent(state: state)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(copyContentIsEmpty(state: state))
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func notesCalendarContextStrip(_ event: CalendarEvent) -> some View {
        let participants = notesContextParticipants(for: event)

        VStack(alignment: .leading, spacing: 8) {
            CalendarEventSummaryRow(
                event: event,
                badge: nil,
                iconName: event.isOnlineMeeting ? "video.fill" : "calendar.badge.checkmark"
            )

            if let organizer = event.organizer?.trimmingCharacters(in: .whitespacesAndNewlines),
               !organizer.isEmpty {
                Label(organizer, systemImage: "person.crop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !participants.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)

                    Text(participantsLabel(for: participants))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .help(participants.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func notesContextParticipants(for event: CalendarEvent) -> [String] {
        let organizerKey = normalizedParticipantKey(event.organizer)

        var named: [String] = []
        var seenNamed: Set<String> = []
        var emails: [String] = []
        var seenEmails: Set<String> = []

        for participant in event.participants {
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                let key = normalizedParticipantKey(name)
                if key != organizerKey, seenNamed.insert(key).inserted {
                    named.append(name)
                }
                continue
            }

            let email = participant.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let email, !email.isEmpty {
                let key = email.lowercased()
                if seenEmails.insert(key).inserted {
                    emails.append(email)
                }
            }
        }

        return !named.isEmpty ? named : emails
    }

    private func normalizedParticipantKey(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func participantsLabel(for participants: [String]) -> String {
        if participants.allSatisfy({ $0.contains("@") }) {
            if participants.count == 1 {
                return "Invited participant: 1 guest"
            }
            return "Invited participants: \(participants.count) guests"
        }

        switch participants.count {
        case 0:
            return ""
        case 1:
            return "Invited participant: \(participants[0])"
        case 2:
            return "Invited participants: \(participants[0]), \(participants[1])"
        case 3:
            return "Invited participants: \(participants[0]), \(participants[1]), \(participants[2])"
        default:
            return "Invited participants: \(participants[0]), \(participants[1]), +\(participants.count - 2) more"
        }
    }

    @ViewBuilder
    private func audioPlaybackButton(controller: NotesController, state: NotesState) -> some View {
        Menu {
            Button {
                controller.toggleAudioPlayback()
            } label: {
                Label(
                    state.isPlayingAudio ? "Pause" : "Play Recording",
                    systemImage: state.isPlayingAudio ? "pause.fill" : "play.fill"
                )
            }
            Divider()
            Button {
                controller.revealAudioInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        } label: {
            Label(
                state.isPlayingAudio ? "Pause" : "Play",
                systemImage: state.isPlayingAudio ? "pause.fill" : "play.fill"
            )
            .font(.system(size: 12))
        } primaryAction: {
            controller.toggleAudioPlayback()
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help(state.isPlayingAudio ? "Pause audio recording" : "Play audio recording")
    }

    @ViewBuilder
    private func transcriptToolbarActions(controller: NotesController, state: NotesState) -> some View {
        let cleanup = cleanupState(from: state.cleanupStatus, transcript: state.loadedTranscript)
        switch cleanup {
        case .notCleaned:
            Button {
                controller.cleanUpTranscript(settings: settings)
            } label: {
                Label("Clean Up", systemImage: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(OpenOatsProminentButtonStyle())
            .disabled(state.loadedTranscript.isEmpty)
            .help("Remove filler words and fix punctuation")

        case .inProgress:
            if case .inProgress(let completed, let total) = state.cleanupStatus {
                HStack(spacing: 6) {
                    Text("\(completed)/\(total) Cleaning up...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        controller.cancelCleanup()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
            }

        case .partiallyCleaned:
            Button {
                controller.cleanUpTranscript(settings: settings)
            } label: {
                Label("Clean Up", systemImage: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(OpenOatsProminentButtonStyle())
            .help("Clean up remaining utterances")

            showOriginalButton(controller: controller, state: state)

        case .cleaned:
            showOriginalButton(controller: controller, state: state)
        }
    }

    @ViewBuilder
    private func showOriginalButton(controller: NotesController, state: NotesState) -> some View {
        Button {
            controller.toggleShowingOriginal()
        } label: {
            Label("Show Original", systemImage: state.showingOriginal ? "text.badge.checkmark" : "text.badge.minus")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .tint(state.showingOriginal ? .accentColor : nil)
        .help(state.showingOriginal ? "Showing original transcript" : "Show original transcript")
    }

    @ViewBuilder
    private func notesToolbarActions(controller: NotesController, state: NotesState) -> some View {
        if let notes = state.loadedNotes {
            Menu {
                ForEach(controller.availableTemplates) { template in
                    Button {
                        controller.regenerateNotes(with: template, settings: settings)
                    } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                    .disabled(notes.template.id == template.id)
                }
            } label: {
                Label(notes.template.name, systemImage: notes.template.icon)
                    .font(.system(size: 12))
            } primaryAction: {
                controller.regenerateNotes(settings: settings)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(controller.isAnyGenerationInProgress)
            .help(controller.isAnyGenerationInProgress
                ? "Generating notes for \"\(controller.generatingSessionName)\"..."
                : "Click to regenerate, or pick a different template")
        }

        imageInsertMenu(controller: controller, state: state)
    }

    @ViewBuilder
    private func imageInsertMenu(controller: NotesController, state: NotesState) -> some View {
        Menu {
            Button {
                insertImageFromFile(controller: controller)
            } label: {
                Label("From File\u{2026}", systemImage: "folder")
            }
            Button {
                insertImageFromClipboard(controller: controller)
            } label: {
                Label("From Clipboard", systemImage: "doc.on.clipboard")
            }
            .disabled(!clipboardHasImage())
            Button {
                captureScreenshot(controller: controller)
            } label: {
                Label("Capture Screenshot", systemImage: "camera.viewfinder")
            }
        } label: {
            Label("Insert Image", systemImage: "photo.badge.plus")
                .font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(state.notesGenerationStatus == .generating || state.selectedSessionID == nil)
        .help("Insert an image into notes")
    }

    private func clipboardHasImage() -> Bool {
        let pb = NSPasteboard.general
        return pb.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier])
    }

    private func insertImageFromFile(controller: NotesController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to insert into notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return }
        controller.insertImage(imageData: pngData)
    }

    private func insertImageFromClipboard(controller: NotesController) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) {
            controller.insertImage(imageData: data)
        } else if let data = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: data),
                  let pngData = rep.representation(using: .png, properties: [:]) {
            controller.insertImage(imageData: pngData)
        }
    }

    private func captureScreenshot(controller: NotesController) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", tempURL.path]
        process.terminationHandler = { proc in
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard proc.terminationStatus == 0,
                  let data = try? Data(contentsOf: tempURL) else { return }
            Task { @MainActor in
                controller.insertImage(imageData: data)
            }
        }
        try? process.run()
    }

    @ViewBuilder
    private func detailBody(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        Group {
            switch detailViewMode {
            case .transcript:
                transcriptView(controller: controller, state: state)
            case .notes:
                notesTab(controller: controller, state: state, sessionID: sessionID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func notesTab(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        switch state.notesGenerationStatus {
        case .generating:
            generatingView(controller: controller, state: state)
        case .idle, .completed, .error:
            if let notes = state.loadedNotes {
                notesContentView(notes, sessionDirectory: state.selectedSessionDirectory)
            } else {
                notesEmptyState(controller: controller, state: state, sessionID: sessionID)
            }
        }
    }

    @ViewBuilder
    private func relatedMeetingSuggestionsSection(
        controller: NotesController,
        suggestions: [MeetingHistorySuggestion],
        showsExistingHistory: Bool,
        linkingSuggestionKey: String?,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 4) {
                    Text(showsExistingHistory ? "Link more meetings" : "Possible related meetings")
                        .font(.system(size: 15, weight: .semibold))
                    Text(
                        showsExistingHistory
                            ? "Bring other renamed titles into this meeting series."
                            : "Link an older title into this meeting series."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        let isLinking = linkingSuggestionKey == suggestion.key
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(suggestion.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)

                                HStack(spacing: 8) {
                                    Text("\(suggestion.sessionCount) past meeting\(suggestion.sessionCount == 1 ? "" : "s")")
                                    if suggestion.notesCount > 0 {
                                        Text("•")
                                        Text("\(suggestion.notesCount) with notes")
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Button {
                                controller.linkMeetingHistorySuggestion(suggestion)
                            } label: {
                                HStack(spacing: 6) {
                                    if isLinking {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(isLinking ? "Linking…" : "Link")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLinking)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func generatingView(controller: NotesController, state: NotesState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating notes...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notes.generating")
                    Spacer()
                    Button("Cancel") {
                        controller.cancelGeneration()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }

                markdownContent(state.streamingMarkdown)
            }
            .padding(16)
        }
    }

    private func notesContentView(_ notes: GeneratedNotes, sessionDirectory: URL?) -> some View {
        ScrollView {
            markdownContent(notes.markdown, sessionDirectory: sessionDirectory)
                .padding(16)
                .accessibilityIdentifier("notes.renderedMarkdown")
        }
    }

    private func notesEmptyState(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        let isEmbeddedMeetingFamilyDetail = state.selectedMeetingFamily != nil

        return ScrollView {
            VStack(spacing: isEmbeddedMeetingFamilyDetail ? 16 : 18) {
                if isEmbeddedMeetingFamilyDetail {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(.tertiary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Generate Notes")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Summarize this transcript into structured meeting notes.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 72)

                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)

                    VStack(spacing: 6) {
                        Text("Generate Notes")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Summarize this transcript into structured meeting notes.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if case .error(let error) = state.notesGenerationStatus {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(error)
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: isEmbeddedMeetingFamilyDetail ? 300 : .infinity, alignment: .leading)
                    .foregroundStyle(.red)
                }

                VStack(spacing: 10) {
                    if let selectedTemplate = state.selectedTemplate {
                        HStack(spacing: 10) {
                            Text("Template")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Menu {
                                ForEach(controller.availableTemplates) { template in
                                    Button {
                                        controller.selectTemplate(template)
                                    } label: {
                                        Label(template.name, systemImage: template.icon)
                                    }
                                    .disabled(selectedTemplate.id == template.id)
                                }
                            } label: {
                                Label(selectedTemplate.name, systemImage: selectedTemplate.icon)
                                    .font(.system(size: 12))
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .help("Choose the note template for the first generation")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }

                    Button {
                        controller.generateNotes(sessionID: sessionID, settings: settings)
                    } label: {
                        Label("Generate Notes", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle())
                    .disabled(state.loadedTranscript.isEmpty || controller.isAnyGenerationInProgress)
                    .accessibilityIdentifier("notes.generateButton")

                    if controller.isAnyGenerationInProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Generating notes for \"\(controller.generatingSessionName)\"...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 300)

                if !isEmbeddedMeetingFamilyDetail {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: isEmbeddedMeetingFamilyDetail ? .topLeading : .center)
            .padding(.horizontal, 24)
            .padding(.vertical, isEmbeddedMeetingFamilyDetail ? 24 : 0)
        }
    }

    // MARK: - Transcript Views

    @ViewBuilder
    private func transcriptView(controller: NotesController, state: NotesState) -> some View {
        if state.loadedTranscript.isEmpty {
            ContentUnavailableView("No Transcript", systemImage: "waveform", description: Text("This session has no recorded utterances."))
        } else {
            ScrollView {
                if case .inProgress(let completed, let total) = state.cleanupStatus {
                    cleanupProgressBanner(controller: controller, completed: completed, total: total)
                }
                if case .error(let cleanupError) = state.cleanupStatus {
                    Text(cleanupError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    let isCleaning: Bool = {
                        if case .inProgress = state.cleanupStatus { return true }
                        return false
                    }()
                    ForEach(Array(state.loadedTranscript.enumerated()), id: \.offset) { _, record in
                        transcriptRow(record: record, isCleaning: isCleaning, showingOriginal: state.showingOriginal)
                    }
                }
                .padding(16)
            }
        }
    }

    private func cleanupProgressBanner(controller: NotesController, completed: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Cleaning up transcript... \(completed)/\(total) sections")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                controller.cancelCleanup()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func transcriptRow(record: SessionRecord, isCleaning: Bool, showingOriginal: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(record.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            let displayText = showingOriginal ? record.text : (record.cleanedText ?? record.text)
            Text(displayText)
                .font(.system(size: 13))
                .foregroundStyle(
                    isCleaning && record.cleanedText == nil ? .secondary : .primary
                )
                .textSelection(.enabled)
        }
    }

    private func copyContentIsEmpty(state: NotesState) -> Bool {
        switch detailViewMode {
        case .transcript:
            return state.loadedTranscript.isEmpty
        case .notes:
            return state.loadedNotes == nil
        }
    }

    // MARK: - Markdown Rendering

    private func markdownContent(_ markdown: String, sessionDirectory: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let sections = parseMarkdownSections(markdown)
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let heading = section.heading {
                    Text(heading)
                        .font(.system(size: section.level == 1 ? 18 : 15, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, section.level == 1 ? 4 : 2)
                }
                if !section.body.isEmpty {
                    sectionBodyView(section.body, sessionDirectory: sessionDirectory)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionBodyView(_ body: String, sessionDirectory: URL?) -> some View {
        let blocks = parseBodyBlocks(body)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .text(let text):
                if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .image(let path):
                if let dir = sessionDirectory,
                   let nsImage = NSImage(contentsOf: dir.appendingPathComponent(path)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 500, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Label("Image not found", systemImage: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private enum BodyBlock {
        case text(String)
        case image(path: String)
    }

    private func parseBodyBlocks(_ body: String) -> [BodyBlock] {
        var blocks: [BodyBlock] = []
        var scanner = body[...]

        while let imgStart = scanner.range(of: "![") {
            let before = String(scanner[scanner.startIndex..<imgStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(before))
            }

            let afterBracket = scanner[imgStart.upperBound...]
            guard let closeBracket = afterBracket.range(of: "]("),
                  let closeParen = afterBracket[closeBracket.upperBound...].range(of: ")") else {
                blocks.append(.text(String(scanner)))
                return blocks
            }

            let path = String(afterBracket[closeBracket.upperBound..<closeParen.lowerBound])
            blocks.append(.image(path: path))
            scanner = afterBracket[closeParen.upperBound...]
        }

        let tail = String(scanner)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(tail))
        }

        return blocks
    }

    private struct MarkdownSection {
        var heading: String?
        var level: Int
        var body: String
    }

    private func parseMarkdownSections(_ markdown: String) -> [MarkdownSection] {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [MarkdownSection] = []
        var currentBody: [String] = []
        var currentHeading: String?
        var currentLevel = 0

        for line in lines {
            if line.hasPrefix("# ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(2))
                currentLevel = 1
                currentBody = []
            } else if line.hasPrefix("## ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(3))
                currentLevel = 2
                currentBody = []
            } else if line.hasPrefix("### ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentHeading = String(line.dropFirst(4))
                currentLevel = 3
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }

        if currentHeading != nil || !currentBody.isEmpty {
            sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    // MARK: - Actions

    private func copyCurrentContent(state: NotesState) {
        let text: String
        switch detailViewMode {
        case .transcript:
            text = state.loadedTranscript.map { record in
                let label = record.speaker.displayLabel
                let content = state.showingOriginal ? record.text : (record.cleanedText ?? record.text)
                return "[\(Self.transcriptTimeFormatter.string(from: record.timestamp))] \(label): \(content)"
            }.joined(separator: "\n")
        case .notes:
            text = state.loadedNotes?.markdown ?? ""
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let transcriptTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - FlowLayout

/// A simple wrapping horizontal layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
