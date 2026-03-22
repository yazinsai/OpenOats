import SwiftUI

struct NotesView: View {
    @Bindable var settings: SettingsStore
    @Environment(NotesController.self) private var notesController

    enum DetailViewMode: String, CaseIterable {
        case transcript = "Transcript"
        case notes = "Notes"
    }

    @State private var detailViewMode: DetailViewMode = .transcript
    @State private var showingOriginal = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        let state = notesController.state

        HStack(spacing: 0) {
            sidebar(state: state)
                .frame(width: 250)
            Divider()
            detailContent(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await notesController.activateIfNeeded()
            if state.loadedSession != nil {
                detailViewMode = .notes
            }
        }
        .onChange(of: state.pendingDeleteSessionID) { _, pending in
            showDeleteConfirmation = pending != nil
        }
        .onChange(of: state.loadedSession?.summary.id) { _, _ in
            if state.loadedSession != nil {
                detailViewMode = .notes
            }
        }
    }

    private func sidebar(state: NotesController.State) -> some View {
        List(state.sessionSummaries, selection: selectionBinding) { session in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let snapshot = session.templateSnapshot {
                        Image(systemName: snapshot.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if state.renamingSessionID == session.id {
                        TextField("Title", text: renameBinding, onCommit: {
                            notesController.commitRename()
                        })
                        .font(.system(size: 13, weight: .medium))
                        .textFieldStyle(.plain)
                        .onExitCommand {
                            notesController.cancelRename()
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
                    notesController.beginRename(sessionID: session.id, existingTitle: session.title)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    notesController.requestDelete(sessionID: session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Delete Meeting?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                notesController.deleteRequestedSession()
            }
            Button("Cancel", role: .cancel) {
                notesController.clearDeleteRequest()
            }
        } message: {
            Text("This will permanently delete the transcript and any generated notes.")
        }
    }

    @ViewBuilder
    private func detailContent(state: NotesController.State) -> some View {
        if let session = state.loadedSession {
            VStack(spacing: 0) {
                detailToolbar(state: state, session: session)
                Divider()
                detailBody(state: state, session: session)
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
            ContentUnavailableView(
                "Select a Session",
                systemImage: "doc.text",
                description: Text("Choose a session from the sidebar to view or generate notes.")
            )
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { notesController.state.selectedSessionID },
            set: { newValue in
                Task {
                    await notesController.selectSession(newValue)
                    if notesController.state.loadedSession != nil {
                        detailViewMode = .notes
                    }
                }
            }
        )
    }

    private var renameBinding: Binding<String> {
        Binding(
            get: { notesController.state.renameText },
            set: { notesController.state.renameText = $0 }
        )
    }

    private enum CleanupState {
        case notCleaned
        case inProgress
        case partiallyCleaned
        case cleaned
    }

    private func cleanupState(for session: SessionDetail, state: NotesController.State) -> CleanupState {
        if state.transcriptCleanupInProgress { return .inProgress }
        guard !session.liveTranscript.isEmpty else { return .notCleaned }
        let hasAnyRefined = session.liveTranscript.contains(where: { $0.refinedText != nil })
        if !hasAnyRefined { return .notCleaned }
        let allRefined = !session.liveTranscript.contains(where: { $0.refinedText == nil })
        return allRefined ? .cleaned : .partiallyCleaned
    }

    private func detailToolbar(
        state: NotesController.State,
        session: SessionDetail
    ) -> some View {
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
                transcriptToolbarActions(state: state, session: session)
            } else {
                notesToolbarActions(state: state)
            }

            Button {
                copyCurrentContent(session: session)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(copyContentIsEmpty(session: session))
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func transcriptToolbarActions(
        state: NotesController.State,
        session: SessionDetail
    ) -> some View {
        switch cleanupState(for: session, state: state) {
        case .notCleaned:
            Button {
                notesController.cleanUpTranscript()
            } label: {
                Label("Clean Up", systemImage: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.liveTranscript.isEmpty)
            .help("Remove filler words and fix punctuation")

        case .inProgress:
            HStack(spacing: 6) {
                Text("\(state.transcriptCleanupChunksCompleted)/\(state.transcriptCleanupTotalChunks) cleaning...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    notesController.cleanupEngine.cancel()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
                .controlSize(.small)
            }

        case .partiallyCleaned:
            Button {
                notesController.cleanUpTranscript()
            } label: {
                Label("Clean Up", systemImage: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .help("Clean up remaining utterances")

            Button {
                showingOriginal.toggle()
            } label: {
                Label("Show Original", systemImage: showingOriginal ? "text.badge.checkmark" : "text.badge.minus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .tint(showingOriginal ? .accentColor : nil)
            .help(showingOriginal ? "Showing original transcript" : "Show original transcript")

        case .cleaned:
            Button {
                showingOriginal.toggle()
            } label: {
                Label("Show Original", systemImage: showingOriginal ? "text.badge.checkmark" : "text.badge.minus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .tint(showingOriginal ? .accentColor : nil)
            .help(showingOriginal ? "Showing original transcript" : "Show original transcript")
        }
    }

    @ViewBuilder
    private func notesToolbarActions(state: NotesController.State) -> some View {
        if let notes = state.loadedSession?.notes {
            Menu {
                ForEach(notesController.templateStore.templates) { template in
                    Button {
                        notesController.regenerateNotes(with: template)
                    } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                    .disabled(notes.template.id == template.id)
                }
            } label: {
                Label(notes.template.name, systemImage: notes.template.icon)
                    .font(.system(size: 12))
            } primaryAction: {
                notesController.regenerateNotes()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Click to regenerate, or pick a different template")
        }
    }

    @ViewBuilder
    private func detailBody(
        state: NotesController.State,
        session: SessionDetail
    ) -> some View {
        switch detailViewMode {
        case .transcript:
            transcriptView(state: state, session: session)
        case .notes:
            notesTab(state: state, session: session)
        }
    }

    @ViewBuilder
    private func notesTab(
        state: NotesController.State,
        session: SessionDetail
    ) -> some View {
        if state.notesGenerationInProgress {
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
                            notesController.notesEngine.cancel()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                    }

                    markdownContent(state.generatedMarkdown)
                }
                .padding(16)
            }
        } else if let notes = session.notes {
            ScrollView {
                markdownContent(notes.markdown)
                    .padding(16)
                    .accessibilityIdentifier("notes.renderedMarkdown")
            }
        } else {
            ContentUnavailableView {
                Label("Generate Notes", systemImage: "sparkles")
            } description: {
                Text("Summarize this transcript into structured meeting notes.")
            } actions: {
                if let error = state.notesGenerationError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                }

                Button {
                    notesController.generateNotes()
                } label: {
                    Label("Generate Notes", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.transcript.isEmpty)
                .accessibilityIdentifier("notes.generateButton")
            }
        }
    }

    @ViewBuilder
    private func transcriptView(
        state: NotesController.State,
        session: SessionDetail
    ) -> some View {
        if session.transcript.isEmpty {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "waveform",
                description: Text("This session has no recorded utterances.")
            )
        } else {
            ScrollView {
                if state.transcriptCleanupInProgress {
                    cleanupProgressBanner(state: state)
                }
                if let cleanupError = state.transcriptCleanupError {
                    Text(cleanupError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.transcript.enumerated()), id: \.offset) { _, record in
                        transcriptRow(record: record, isCleaning: state.transcriptCleanupInProgress)
                    }
                }
                .padding(16)
            }
        }
    }

    private func cleanupProgressBanner(state: NotesController.State) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Cleaning up transcript... \(state.transcriptCleanupChunksCompleted)/\(state.transcriptCleanupTotalChunks) sections")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                notesController.cleanupEngine.cancel()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func transcriptRow(record: SessionRecord, isCleaning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(record.speaker.presentationColor)
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

    private func copyContentIsEmpty(session: SessionDetail) -> Bool {
        switch detailViewMode {
        case .transcript:
            return session.transcript.isEmpty
        case .notes:
            return session.notes == nil && notesController.state.generatedMarkdown.isEmpty
        }
    }

    private func copyCurrentContent(session: SessionDetail) {
        let text: String
        switch detailViewMode {
        case .transcript:
            text = session.transcript.map { record in
                let content = showingOriginal ? record.text : (record.refinedText ?? record.text)
                return "[\(Self.transcriptTimeFormatter.string(from: record.timestamp))] \(record.speaker.displayLabel): \(content)"
            }.joined(separator: "\n")
        case .notes:
            text = session.notes?.markdown ?? notesController.state.generatedMarkdown
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

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
                    if let attributed = try? AttributedString(
                        markdown: section.body,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
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
                    sections.append(MarkdownSection(
                        heading: currentHeading,
                        level: currentLevel,
                        body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                currentHeading = String(line.dropFirst(2))
                currentLevel = 1
                currentBody = []
            } else if line.hasPrefix("## ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(
                        heading: currentHeading,
                        level: currentLevel,
                        body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                currentHeading = String(line.dropFirst(3))
                currentLevel = 2
                currentBody = []
            } else if line.hasPrefix("### ") {
                if currentHeading != nil || !currentBody.isEmpty {
                    sections.append(MarkdownSection(
                        heading: currentHeading,
                        level: currentLevel,
                        body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                currentHeading = String(line.dropFirst(4))
                currentLevel = 3
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }

        if currentHeading != nil || !currentBody.isEmpty {
            sections.append(MarkdownSection(
                heading: currentHeading,
                level: currentLevel,
                body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return sections
    }

    private static let transcriptTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
