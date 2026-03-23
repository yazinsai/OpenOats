import SwiftUI

struct NotesView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @State private var notesController: NotesController?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
    @State private var sessionToDelete: String?
    @State private var showDeleteConfirmation = false

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
                detailViewMode = .notes
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
        let selectedBinding = Binding<String?>(
            get: { state.selectedSessionID },
            set: { controller.selectSession($0) }
        )
        List(state.sessionHistory, selection: selectedBinding) { session in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let snap = session.templateSnapshot {
                        Image(systemName: snap.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if renamingSessionID == session.id {
                        TextField("Title", text: $renameText, onCommit: {
                            controller.renameSession(sessionID: session.id, newTitle: renameText)
                            renamingSessionID = nil
                        })
                        .font(.system(size: 13, weight: .medium))
                        .textFieldStyle(.plain)
                        .onExitCommand {
                            renamingSessionID = nil
                        }
                    } else {
                        Text(session.title ?? "Untitled")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    if session.hasNotes {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(session.startedAt, style: .date)
                    Text(session.startedAt, style: .time)
                    Spacer()
                    Text("\(session.utteranceCount) utterances")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("notes.session.\(session.id)")
            .contextMenu {
                Button("Rename...") {
                    renameText = session.title ?? ""
                    renamingSessionID = session.id
                }
                Divider()
                Button("Delete", role: .destructive) {
                    sessionToDelete = session.id
                    showDeleteConfirmation = true
                }
            }
        }
        .listStyle(.sidebar)
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
            ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text("Choose a session from the sidebar to view or generate notes."))
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
            .buttonStyle(.borderedProminent)
            .disabled(state.loadedTranscript.isEmpty)
            .help("Remove filler words and fix punctuation")

        case .inProgress:
            if case .inProgress(let completed, let total) = state.cleanupStatus {
                HStack(spacing: 6) {
                    Text("\(completed)/\(total) cleaning...")
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
            .buttonStyle(.borderedProminent)
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
            .help("Click to regenerate, or pick a different template")
        }
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
                notesContentView(notes)
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

    private func notesContentView(_ notes: EnhancedNotes) -> some View {
        ScrollView {
            markdownContent(notes.markdown)
                .padding(16)
                .accessibilityIdentifier("notes.renderedMarkdown")
        }
    }

    private func notesEmptyState(controller: NotesController, state: NotesState, sessionID: String) -> some View {
        ContentUnavailableView {
            Label("Generate Notes", systemImage: "sparkles")
        } description: {
            Text("Summarize this transcript into structured meeting notes.")
        } actions: {
            if case .error(let error) = state.notesGenerationStatus {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }

            Button {
                controller.generateNotes(sessionID: sessionID, settings: settings)
            } label: {
                Label("Generate Notes", systemImage: "sparkles")
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

            let displayText = showingOriginal ? record.text : (record.refinedText ?? record.text)
            Text(displayText)
                .font(.system(size: 13))
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

    private func markdownContent(_ markdown: String) -> some View {
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
                    if let attributed = try? AttributedString(markdown: section.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(section.body)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
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
