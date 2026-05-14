import AppKit
import SwiftUI

struct NotesView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container
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
    @State private var showingAddTranscriptSheet = false
    @State private var manualTranscriptDraft = ""
    @State private var collapsedSidebarGroupIDs = Self.loadCollapsedSidebarGroupIDs()

    @State private var detailViewMode: MeetingDetailViewMode = .transcript

    var body: some View {
        Group {
            if let controller = notesController {
                mainContent(controller: controller)
            } else {
                ProgressView()
            }
        }
        .task {
            if coordinator.knowledgeBase == nil {
                container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
            }
            let controller = NotesController(coordinator: coordinator, settings: settings)
            notesController = controller
            await controller.loadHistory()

            if await handleRequestedNotesNavigation(controller: controller) {
                return
            } else if let last = coordinator.lastEndedSession {
                controller.selectSession(last.id)
            }
        }
    }

    @ViewBuilder
    private func mainContent(controller: NotesController) -> some View {
        let state = controller.state
        mainLayout(controller: controller, state: state)
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

    @ViewBuilder
    private func mainLayout(controller: NotesController, state: NotesState) -> some View {
        HStack(spacing: 0) {
            sidebar(controller: controller, state: state)
                .frame(width: OpenOatsWindowSizing.notesWorkspaceSidebarWidth)
            Divider()
            MeetingDetailPane(
                settings: settings,
                controller: controller,
                state: state,
                detailViewMode: $detailViewMode,
                isAddTranscriptPresented: $showingAddTranscriptSheet,
                manualTranscriptDraft: $manualTranscriptDraft
            ) { session in
                folderAssignmentMenu(controller: controller, session: session)
            }
            .frame(
                minWidth: OpenOatsWindowSizing.meetingDetailPaneMinWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            Task { await controller.handleLastEndedSessionChanged() }
        }
        .onChange(of: coordinator.sessionHistory) {
            Task { await controller.handleSessionHistoryChanged() }
        }
        .onChange(of: coordinator.batchStatus) { _, newStatus in
            if case .completed = newStatus {
                Task { await controller.loadHistory() }
            }
        }
        .onChange(of: coordinator.requestedNotesNavigation?.id) {
            Task {
                _ = await handleRequestedNotesNavigation(controller: controller)
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
                        ForEach(controller.folderGroups) { group in
                            Section {
                                if isSidebarGroupExpanded(collapseID(for: group)) {
                                    ForEach(group.sessions) { session in
                                        sessionRow(controller: controller, session: session)
                                    }
                                }
                            } header: {
                                collapsibleFolderSectionHeader(group)
                            }
                        }
                    } else if controller.showsSourceSections {
                        ForEach(controller.sessionSourceGroups) { group in
                            Section {
                                if isSidebarGroupExpanded(collapseID(for: group)) {
                                    ForEach(group.sessions) { session in
                                        sessionRow(controller: controller, session: session)
                                    }
                                }
                            } header: {
                                collapsibleSourceSectionHeader(group)
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
                        ForEach(controller.folderGroups) { group in
                            Section {
                                if isSidebarGroupExpanded(collapseID(for: group)) {
                                    ForEach(group.sessions) { session in
                                        sessionListEntry(controller: controller, session: session)
                                    }
                                }
                            } header: {
                                collapsibleFolderSectionHeader(group)
                            }
                        }
                    } else if controller.showsSourceSections {
                        ForEach(controller.sessionSourceGroups) { group in
                            Section {
                                if isSidebarGroupExpanded(collapseID(for: group)) {
                                    ForEach(group.sessions) { session in
                                        sessionListEntry(controller: controller, session: session)
                                    }
                                }
                            } header: {
                                collapsibleSourceSectionHeader(group)
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
                Text(session.notesTranscriptStatusText)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            if let recovery = session.transcriptRecovery {
                Text(recovery.listLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }

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
        folderEditorSheet(
            title: "New Folder",
            subtitle: "Use `/` to create subfolders inside your Notes list.",
            saveDisabled: NotesFolderDefinition.normalizePath(newFolderPath) == nil,
            onSave: {
                commitCreateFolder(controller: controller, sessionID: sessionID)
            }
        )
        .accessibilityIdentifier("notes.newFolderSheet")
    }

    @ViewBuilder
    private func folderEditorSheet(
        title: String,
        subtitle: String,
        saveDisabled: Bool,
        onSave: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            Text(subtitle)
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
                    onSave()
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
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
                .accessibilityIdentifier("notes.newFolderSheet.saveButton")
            }
        }
        .padding(20)
        .frame(width: 360)
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
    private func collapsibleFolderSectionHeader(_ group: SessionFolderGroup) -> some View {
        collapsibleSidebarSectionHeader(
            title: group.title,
            systemImage: group.isRoot ? "folder" : "folder.fill",
            iconColor: group.isRoot ? .secondary : folderColor(for: group.id),
            collapseID: collapseID(for: group)
        )
    }

    @ViewBuilder
    private func collapsibleSourceSectionHeader(_ group: SessionSourceGroup) -> some View {
        collapsibleSidebarSectionHeader(
            title: group.title,
            systemImage: "tray.full",
            iconColor: .secondary,
            collapseID: collapseID(for: group)
        )
    }

    @ViewBuilder
    private func collapsibleSidebarSectionHeader(
        title: String,
        systemImage: String,
        iconColor: Color,
        collapseID: String
    ) -> some View {
        Button {
            toggleSidebarGroup(collapseID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSidebarGroupExpanded(collapseID) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func collapseID(for group: SessionFolderGroup) -> String {
        "folder:\(group.id)"
    }

    private func collapseID(for group: SessionSourceGroup) -> String {
        "source:\(group.id)"
    }

    private func isSidebarGroupExpanded(_ collapseID: String) -> Bool {
        !collapsedSidebarGroupIDs.contains(collapseID)
    }

    private func toggleSidebarGroup(_ collapseID: String) {
        if collapsedSidebarGroupIDs.contains(collapseID) {
            collapsedSidebarGroupIDs.remove(collapseID)
        } else {
            collapsedSidebarGroupIDs.insert(collapseID)
        }
        persistCollapsedSidebarGroupIDs()
    }

    private func persistCollapsedSidebarGroupIDs() {
        UserDefaults.standard.set(Array(collapsedSidebarGroupIDs).sorted(), forKey: Self.collapsedSidebarGroupsDefaultsKey)
    }

    private static let collapsedSidebarGroupsDefaultsKey = "notesCollapsedSidebarGroups"

    private static func loadCollapsedSidebarGroupIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedSidebarGroupsDefaultsKey) ?? [])
    }

    @MainActor
    private func handleRequestedNotesNavigation(controller: NotesController) async -> Bool {
        guard let requested = coordinator.consumeRequestedSessionSelection() else { return false }

        switch requested {
        case .session(let sessionID):
            controller.selectSession(sessionID)
            let isImported = controller.state.sessionHistory.first(where: { $0.id == sessionID })?.source == "imported"
            detailViewMode = isImported ? .transcript : .notes
        case .transcriptSession(let sessionID):
            controller.selectSession(sessionID)
            detailViewMode = .transcript
        case .retranscribeSession(let sessionID):
            controller.selectSession(sessionID)
            detailViewMode = .transcript
            try? await Task.sleep(for: .milliseconds(200))
            if controller.state.canRetranscribeSelectedSession {
                container.ensureRecordingServicesInitialized(settings: settings, coordinator: coordinator)
                controller.rerunBatchTranscription(
                    model: settings.batchTranscriptionModel,
                    settings: settings
                )
            }
        case .meetingHistory(let event):
            controller.showMeetingFamily(for: event)
            detailViewMode = .notes
        case .manualTranscript(let event):
            detailViewMode = .transcript
            let shouldPromptForTranscript = await controller.prepareManualTranscriptSession(for: event)
            if shouldPromptForTranscript {
                beginAddTranscript()
            }
        case .clearSelection:
            controller.selectSession(nil)
            detailViewMode = .notes
        }

        return true
    }

    private func beginAddTranscript() {
        manualTranscriptDraft = ""
        showingAddTranscriptSheet = true
    }
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
