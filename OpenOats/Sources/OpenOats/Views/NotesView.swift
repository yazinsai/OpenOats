import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @State private var notesController: NotesController?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
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

    @State private var detailViewMode: DetailViewMode = .transcript

    var body: some View {
        Group {
            if let controller = notesController {
                mainContent(controller: controller)
            } else {
                ProgressView()
            }
        }
        .task {
            let controller = NotesController(coordinator: coordinator)
            notesController = controller
            await controller.loadHistory()

            // Handle pending navigation — inline rather than via controller
            // to ensure @State detailViewMode update happens in the same
            // transaction as session selection (matches pre-Phase 6 behavior).
            if let requested = coordinator.consumeRequestedSessionSelection() {
                controller.selectSession(requested)
                // Show Transcript tab for imported sessions (no notes generated yet)
                let isImported = controller.state.sessionHistory.first(where: { $0.id == requested })?.source == "imported"
                detailViewMode = isImported ? .transcript : .notes
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
        .onChange(of: coordinator.requestedSessionSelectionID) {
            if controller.handleRequestedSessionSelection() {
                detailViewMode = .notes
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
                    Button(String(localized: "select_all")) {
                        bulkDeleteSelection = Set(controller.filteredSessions.map(\.id))
                    }
.accessibilityLabel(String(localized: "select_all"))
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    if !bulkDeleteSelection.isEmpty {
                        Button(String(localized: "delete_bulkdeleteselectioncount")) {
                            showBulkDeleteConfirmation = true
                        }
.accessibilityLabel(String(localized: "delete_bulkdeleteselectioncount"))
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
.accessibilityAddTraits(.updatesFrequently)
                    }
                    Button(String(localized: "done")) {
                        bulkDeleteMode = false
                        bulkDeleteSelection = []
                    }
.accessibilityLabel(String(localized: "done"))
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            if bulkDeleteMode {
                List(controller.filteredSessions, selection: $bulkDeleteSelection) { session in
                    sessionRow(controller: controller, session: session)
                }
                .listStyle(.sidebar)
            } else {
                let selectedBinding = Binding<String?>(
                    get: { state.selectedSessionID },
                    set: { controller.selectSession($0) }
                )
                List(controller.filteredSessions, selection: selectedBinding) { session in
                    sessionRow(controller: controller, session: session)
                        .contextMenu {
                            Button(String(localized: "rename")) {
                                renameText = session.title ?? ""
                                renamingSessionID = session.id
                            }
.accessibilityLabel(String(localized: "rename"))
                            Button(String(localized: "edit_tags")) {
                                editingTags = session.tags ?? []
                                newTagText = ""
                                editingTagsSessionID = session.id
                                Task {
                                    availableTags = await controller.allTags()
                                }
.accessibilityLabel(String(localized: "edit_tags"))
                            }
                            Divider()
                            Button(String(localized: "select_multiple")) {
                                bulkDeleteMode = true
                                bulkDeleteSelection = [session.id]
                            }
.accessibilityLabel(String(localized: "select_multiple"))
                            Divider()
                            Button("Delete", role: .destructive) {
                                sessionToDelete = session.id
                                showDeleteConfirmation = true
                            }
                        }
                        .popover(isPresented: Binding(
                            get: { editingTagsSessionID == session.id },
                            set: { if !$0 { editingTagsSessionID = nil } }
                        )) {
                            tagEditorPopover(controller: controller, sessionID: session.id)
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
            Text(String(localized: "this_will_permanently_delete_the_transcript_and_an"))
        }
        .alert("Delete \(bulkDeleteSelection.count) Meetings?", isPresented: $showBulkDeleteConfirmation) {
            Button("Delete \(bulkDeleteSelection.count)", role: .destructive) {
                controller.deleteSessions(sessionIDs: bulkDeleteSelection)
                bulkDeleteMode = false
                bulkDeleteSelection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "this_will_permanently_delete_the_selected_transcri"))
        }
    }

    @ViewBuilder
    private func sessionRow(controller: NotesController, session: SessionIndex) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let snap = session.templateSnapshot {
                    Image(systemName: snap.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if renamingSessionID == session.id {
                    TextField("Title", text: $renameText, onCommit: {
                        controller.renameSession(sessionID: session.id, newTitle: renameText)
.accessibilityLabel(String(localized: "textfield_title_label"))
                        renamingSessionID = nil
                    })
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .onExitCommand {
                        renamingSessionID = nil
                    }
                } else {
                    Text(session.title ?? "Untitled")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                Spacer()
                if session.hasNotes {
                    Image(systemName: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Text(session.startedAt, style: .date)
                Text(session.startedAt, style: .time)
                Spacer()
                Text(String(localized: "sessionutterancecount_utterances"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let tags = session.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
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
                                .font(.caption)
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
            for tag in session.tags ?? [] {
                let key = tag.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(tag)
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Tag Editor Popover

    @ViewBuilder
    private func tagEditorPopover(controller: NotesController, sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "tags"))
                .font(.headline)

            // Current tags as removable chips
            if !editingTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(editingTags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag)
                                .font(.footnote)
                            Button {
                                editingTags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                                controller.updateSessionTags(sessionID: sessionID, tags: editingTags)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
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
.accessibilityLabel(String(localized: "textfield_add_tag..._label"))
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .onSubmit {
                            commitNewTag(controller: controller, sessionID: sessionID)
                        }
                    Button(String(localized: "add")) {
                        commitNewTag(controller: controller, sessionID: sessionID)
                    }
.accessibilityLabel(String(localized: "add"))
.accessibilityHint(String(localized: "add_item_hint"))
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
                                    .font(.footnote)
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
                Text(String(localized: "maximum_5_tags_per_session"))
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
        if let sessionID = state.selectedSessionID {
            VStack(spacing: 0) {
                detailToolbar(controller: controller, state: state)
                Divider()
                detailBody(controller: controller, state: state, sessionID: sessionID)
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
        } else {
            ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text(String(localized: "choose_a_session_from_the_sidebar_to_view_or_gener")))
        }
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
        let hasAnyRefined = transcript.contains(where: { $0.refinedText != nil })
        if !hasAnyRefined { return .notCleaned }
        let allRefined = !transcript.contains(where: { $0.refinedText == nil })
        return allRefined ? .cleaned : .partiallyCleaned
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

            Button {
                copyCurrentContent(state: state)
            } label: {
                Label(String(localized: "copy"), systemImage: "doc.on.doc")
                    .font(.footnote)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(copyContentIsEmpty(state: state))
            .help(String(localized: "copy_to_clipboard"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func transcriptToolbarActions(controller: NotesController, state: NotesState) -> some View {
        let cleanup = cleanupState(from: state.cleanupStatus, transcript: state.loadedTranscript)
        switch cleanup {
        case .notCleaned:
            Button {
                controller.cleanUpTranscript(settings: settings)
            } label: {
                Label(String(localized: "clean_up"), systemImage: "sparkles")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.loadedTranscript.isEmpty)
            .help(String(localized: "remove_filler_words_and_fix_punctuation"))

        case .inProgress:
            if case .inProgress(let completed, let total) = state.cleanupStatus {
                HStack(spacing: 6) {
                    Text(String(localized: "completedtotal_cleaning"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "cancel")) {
                        controller.cancelCleanup()
                    }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .controlSize(.small)
                }
            }

        case .partiallyCleaned:
            Button {
                controller.cleanUpTranscript(settings: settings)
            } label: {
                Label(String(localized: "clean_up"), systemImage: "sparkles")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .help(String(localized: "clean_up_remaining_utterances"))

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
            Label(String(localized: "show_original"), systemImage: state.showingOriginal ? "text.badge.checkmark" : "text.badge.minus")
                .font(.footnote)
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
                    .font(.footnote)
            } primaryAction: {
                controller.regenerateNotes(settings: settings)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help(String(localized: "click_to_regenerate_or_pick_a_different_template"))
        }

        imageInsertMenu(controller: controller, state: state)
    }

    @ViewBuilder
    private func imageInsertMenu(controller: NotesController, state: NotesState) -> some View {
        Menu {
            Button {
                insertImageFromFile(controller: controller)
            } label: {
                Label(String(localized: "from_fileu2026"), systemImage: "folder")
            }
            Button {
                insertImageFromClipboard(controller: controller)
            } label: {
                Label(String(localized: "from_clipboard"), systemImage: "doc.on.clipboard")
            }
            .disabled(!clipboardHasImage())
            Button {
                captureScreenshot(controller: controller)
            } label: {
                Label(String(localized: "capture_screenshot"), systemImage: "camera.viewfinder")
            }
        } label: {
            Label(String(localized: "insert_image"), systemImage: "photo.badge.plus")
                .font(.footnote)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(state.notesGenerationStatus == .generating || state.selectedSessionID == nil)
        .help(String(localized: "insert_an_image_into_notes"))
    }

    private func clipboardHasImage() -> Bool {
        let pb = NSPasteboard.general
        return pb.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier])
    }

    private func insertImageFromFile(controller: NotesController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "choose_an_image_to_insert_into_notes")
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

    private func generatingView(controller: NotesController, state: NotesState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "generating_notes"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notes.generating")
                    Spacer()
                    Button(String(localized: "cancel")) {
                        controller.cancelGeneration()
                    }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
                    .buttonStyle(.bordered)
                    .font(.caption)
                }

                markdownContent(state.streamingMarkdown)
            }
            .padding(16)
        }
    }

    private func notesContentView(_ notes: EnhancedNotes, sessionDirectory: URL?) -> some View {
        ScrollView {
            markdownContent(notes.markdown, sessionDirectory: sessionDirectory)
                .padding(16)
                .accessibilityIdentifier("notes.renderedMarkdown")
        }
    }

    private func notesEmptyState(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        ContentUnavailableView {
            Label(String(localized: "generate_notes"), systemImage: "sparkles")
        } description: {
            Text(String(localized: "summarize_this_transcript_into_structured_meeting_"))
        } actions: {
            if case .error(let error) = state.notesGenerationStatus {
                Text(error)
                    .foregroundStyle(.red)
.accessibilityAddTraits(.updatesFrequently)
                    .font(.footnote)
            }

            Button {
                controller.generateNotes(sessionID: sessionID, settings: settings)
            } label: {
                Label(String(localized: "generate_notes"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.loadedTranscript.isEmpty)
            .accessibilityIdentifier("notes.generateButton")
        }
    }

    // MARK: - Transcript Views

    @ViewBuilder
    private func transcriptView(controller: NotesController, state: NotesState) -> some View {
        if state.loadedTranscript.isEmpty {
            ContentUnavailableView("No Transcript", systemImage: "waveform", description: Text(String(localized: "this_session_has_no_recorded_utterances")))
        } else {
            ScrollView {
                if case .inProgress(let completed, let total) = state.cleanupStatus {
                    cleanupProgressBanner(controller: controller, completed: completed, total: total)
                }
                if case .error(let cleanupError) = state.cleanupStatus {
                    Text(cleanupError)
                        .font(.footnote)
                        .foregroundStyle(.red)
.accessibilityAddTraits(.updatesFrequently)
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
            Text(String(localized: "cleaning_up_transcript_completedtotal_sections"))
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "cancel")) {
                controller.cancelCleanup()
            }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func transcriptRow(record: SessionRecord, isCleaning: Bool, showingOriginal: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.speaker.displayLabel)
                .font(.caption)
                .foregroundStyle(record.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            let displayText = showingOriginal ? record.text : (record.refinedText ?? record.text)
            Text(displayText)
                .font(.subheadline)
                .foregroundStyle(
                    isCleaning && record.refinedText == nil ? .secondary : .primary
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
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.subheadline)
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
                    Label(String(localized: "image_not_found"), systemImage: "photo")
                        .font(.footnote)
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
                let content = state.showingOriginal ? record.text : (record.refinedText ?? record.text)
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
