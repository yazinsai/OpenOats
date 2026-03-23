import SwiftUI

struct NotesView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedSessionID: String?
    @State private var loadedNotes: EnhancedNotes?
    @State private var loadedTranscript: [SessionRecord] = []
    @State private var selectedTemplateForGeneration: MeetingTemplate?
    @State private var renamingSessionID: String?
    @State private var renameText: String = ""
    @State private var sessionToDelete: String?
    @State private var showDeleteConfirmation = false

    enum DetailViewMode: String, CaseIterable {
        case transcript = "Transcript"
        case notes = "Notes"
    }

    @State private var detailViewMode: DetailViewMode = .transcript
    @State private var showingOriginal = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await coordinator.loadHistory()
            if let requested = coordinator.consumeRequestedSessionSelection() {
                selectedSessionID = requested
                detailViewMode = .notes
            } else if let last = coordinator.lastEndedSession {
                selectedSessionID = last.id
            }
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            if let last = coordinator.lastEndedSession {
                Task {
                    await coordinator.loadHistory()
                    selectedSessionID = last.id
                }
            }
        }
        .onChange(of: coordinator.requestedSessionSelectionID) {
            if let requested = coordinator.consumeRequestedSessionSelection() {
                selectedSessionID = requested
                // Deep links target notes, so default to the Notes tab
                detailViewMode = .notes
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(coordinator.sessionHistory, selection: $selectedSessionID) { session in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let snap = session.templateSnapshot {
                        Image(systemName: snap.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if renamingSessionID == session.id {
                        TextField("Title", text: $renameText, onCommit: {
                            commitRename(sessionID: session.id)
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
        .onChange(of: selectedSessionID) {
            loadSelectedSession()
        }
        .alert("Delete Meeting?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = sessionToDelete {
                    deleteSession(sessionID: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the transcript and any generated notes.")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let sessionID = selectedSessionID {
            VStack(spacing: 0) {
                detailToolbar
                Divider()
                detailBody(sessionID: sessionID)
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

    private var cleanupState: CleanupState {
        if coordinator.cleanupEngine.isCleaningUp { return .inProgress }
        guard !loadedTranscript.isEmpty else { return .notCleaned }
        let hasAnyRefined = loadedTranscript.contains(where: { $0.refinedText != nil })
        if !hasAnyRefined { return .notCleaned }
        let allRefined = !loadedTranscript.contains(where: { $0.refinedText == nil })
        return allRefined ? .cleaned : .partiallyCleaned
    }

    @ViewBuilder
    private var detailToolbar: some View {
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
                transcriptToolbarActions
            } else if detailViewMode == .notes {
                notesToolbarActions
            }

            Button {
                copyCurrentContent()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(copyContentIsEmpty)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcriptToolbarActions: some View {
        switch cleanupState {
        case .notCleaned:
            Button {
                cleanUpTranscript()
            } label: {
                Label("Clean Up", systemImage: "sparkles")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .disabled(loadedTranscript.isEmpty)
            .help("Remove filler words and fix punctuation")

        case .inProgress:
            HStack(spacing: 6) {
                Text("\(coordinator.cleanupEngine.chunksCompleted)/\(coordinator.cleanupEngine.totalChunks) cleaning...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    coordinator.cleanupEngine.cancel()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
                .controlSize(.small)
            }

        case .partiallyCleaned:
            Button {
                cleanUpTranscript()
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
    private var notesToolbarActions: some View {
        if let notes = loadedNotes {
            Menu {
                ForEach(coordinator.templateStore.templates) { template in
                    Button {
                        regenerateNotes(with: template)
                    } label: {
                        Label(template.name, systemImage: template.icon)
                    }
                    .disabled(notes.template.id == template.id)
                }
            } label: {
                Label(notes.template.name, systemImage: notes.template.icon)
                    .font(.system(size: 12))
            } primaryAction: {
                regenerateNotes()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Click to regenerate, or pick a different template")
        }
    }

    @ViewBuilder
    private func detailBody(sessionID: String) -> some View {
        Group {
            switch detailViewMode {
            case .transcript:
                transcriptView
            case .notes:
                notesTab(sessionID: sessionID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func notesTab(sessionID: String) -> some View {
        if coordinator.notesEngine.isGenerating {
            generatingView
        } else if let notes = loadedNotes {
            notesContentView(notes)
        } else {
            notesEmptyState(sessionID: sessionID)
        }
    }

    private var generatingView: some View {
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
                        coordinator.notesEngine.cancel()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }

                markdownContent(coordinator.notesEngine.generatedMarkdown)
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

    private func notesEmptyState(sessionID: String) -> some View {
        ContentUnavailableView {
            Label("Generate Notes", systemImage: "sparkles")
        } description: {
            Text("Summarize this transcript into structured meeting notes.")
        } actions: {
            if let error = coordinator.notesEngine.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }

            Button {
                generateNotes(sessionID: sessionID)
            } label: {
                Label("Generate Notes", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(loadedTranscript.isEmpty)
            .accessibilityIdentifier("notes.generateButton")
        }
    }

    // MARK: - Transcript Views

    @ViewBuilder
    private var transcriptView: some View {
        if loadedTranscript.isEmpty {
            ContentUnavailableView("No Transcript", systemImage: "waveform", description: Text("This session has no recorded utterances."))
        } else {
            ScrollView {
                if coordinator.cleanupEngine.isCleaningUp {
                    cleanupProgressBanner
                }
                if let cleanupError = coordinator.cleanupEngine.error {
                    Text(cleanupError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    let isCleaning = coordinator.cleanupEngine.isCleaningUp
                    ForEach(Array(loadedTranscript.enumerated()), id: \.offset) { _, record in
                        transcriptRow(record: record, isCleaning: isCleaning)
                    }
                }
                .padding(16)
            }
        }
    }

    private var cleanupProgressBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Cleaning up transcript... \(coordinator.cleanupEngine.chunksCompleted)/\(coordinator.cleanupEngine.totalChunks) sections")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                coordinator.cleanupEngine.cancel()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func transcriptRow(record: SessionRecord, isCleaning: Bool) -> some View {
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

    private var copyContentIsEmpty: Bool {
        switch detailViewMode {
        case .transcript:
            return loadedTranscript.isEmpty
        case .notes:
            return loadedNotes == nil
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

    private func copyCurrentContent() {
        let text: String
        switch detailViewMode {
        case .transcript:
            text = loadedTranscript.map { record in
                let label = record.speaker.displayLabel
                let content = showingOriginal ? record.text : (record.refinedText ?? record.text)
                return "[\(Self.transcriptTimeFormatter.string(from: record.timestamp))] \(label): \(content)"
            }.joined(separator: "\n")
        case .notes:
            text = loadedNotes?.markdown ?? ""
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadSelectedSession() {
        guard let sessionID = selectedSessionID else {
            loadedNotes = nil
            loadedTranscript = []
            return
        }

        loadedNotes = nil
        loadedTranscript = []
        showingOriginal = false
        coordinator.cleanupEngine.cancel()

        Task {
            let notes = await coordinator.sessionStore.loadNotes(sessionID: sessionID)
            let transcript = await coordinator.sessionStore.loadTranscript(sessionID: sessionID)

            guard selectedSessionID == sessionID else { return }

            loadedNotes = notes
            loadedTranscript = transcript

            let session = coordinator.sessionHistory.first { $0.id == sessionID }
            if let snapID = session?.templateSnapshot?.id {
                selectedTemplateForGeneration = coordinator.templateStore.template(for: snapID)
            } else {
                selectedTemplateForGeneration = coordinator.templateStore.template(for: TemplateStore.genericID)
            }
        }
    }

    private func generateNotes(sessionID: String) {
        let template = selectedTemplateForGeneration
            ?? coordinator.templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first!

        Task {
            await coordinator.notesEngine.generate(
                transcript: loadedTranscript,
                template: template,
                settings: settings
            )

            if !coordinator.notesEngine.generatedMarkdown.isEmpty {
                let notes = EnhancedNotes(
                    template: coordinator.templateStore.snapshot(of: template),
                    generatedAt: Date(),
                    markdown: coordinator.notesEngine.generatedMarkdown
                )
                await coordinator.sessionStore.saveNotes(sessionID: sessionID, notes: notes)
                loadedNotes = notes

                // Update the structured Markdown file with LLM-generated sections
                let outputDir = URL(fileURLWithPath: settings.notesFolderPath)
                if let mdFile = MarkdownMeetingWriter.findMarkdownFile(
                    sessionID: sessionID,
                    in: outputDir
                ) {
                    MarkdownMeetingWriter.insertLLMSections(
                        fileURL: mdFile,
                        llmMarkdown: coordinator.notesEngine.generatedMarkdown
                    )
                }

                await coordinator.loadHistory()
            }
        }
    }

    private func commitRename(sessionID: String) {
        renamingSessionID = nil
        Task {
            await coordinator.sessionStore.renameSession(sessionID: sessionID, newTitle: renameText)
            await coordinator.loadHistory()
        }
    }

    private func deleteSession(sessionID: String) {
        Task {
            await coordinator.sessionStore.deleteSession(sessionID: sessionID)
            if selectedSessionID == sessionID {
                selectedSessionID = nil
                loadedNotes = nil
                loadedTranscript = []
            }
            await coordinator.loadHistory()
        }
    }

    private func regenerateNotes(with template: MeetingTemplate? = nil) {
        guard let sessionID = selectedSessionID else { return }
        if let template {
            selectedTemplateForGeneration = template
        }
        loadedNotes = nil
        generateNotes(sessionID: sessionID)
    }

    private static let transcriptTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func cleanUpTranscript() {
        guard let sessionID = selectedSessionID, !loadedTranscript.isEmpty else { return }

        Task {
            let updated = await coordinator.cleanupEngine.cleanup(
                records: loadedTranscript,
                settings: settings
            )

            let utterances = updated.map { record in
                Utterance(
                    text: record.text,
                    speaker: record.speaker,
                    timestamp: record.timestamp,
                    refinedText: record.refinedText
                )
            }
            await coordinator.sessionStore.backfillRefinedText(sessionID: sessionID, from: utterances)

            guard selectedSessionID == sessionID else { return }
            loadedTranscript = await coordinator.sessionStore.loadTranscript(sessionID: sessionID)
        }
    }
}
