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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .task {
            await coordinator.loadHistory()
            if let requested = coordinator.consumeRequestedSessionSelection() {
                selectedSessionID = requested
            } else if let last = coordinator.lastEndedSession {
                selectedSessionID = last.id
            }
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            // When a new session ends (even if Notes window is already open),
            // refresh history and auto-select it
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
            }
        }
        .onChange(of: coordinator.sessionHistory.count) {
            // Refresh sidebar when history changes
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
        .navigationTitle("Sessions")
        .frame(minWidth: 200)
        .accessibilityIdentifier("notes.sessionList")
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
                if coordinator.notesEngine.isGenerating {
                    generatingView
                } else if let notes = loadedNotes {
                    notesReadyView(notes)
                } else {
                    noNotesView(sessionID: sessionID)
                }
            }
        } else {
            ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text("Choose a session from the sidebar to view or generate notes."))
        }
    }

    private var generatingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Generating notes...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notes.generating")
                    Spacer()
                    Button("Cancel") {
                        coordinator.notesEngine.cancel()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                markdownContent(coordinator.notesEngine.generatedMarkdown)
            }
            .padding(20)
        }
    }

    private func notesReadyView(_ notes: EnhancedNotes) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Label(notes.template.name, systemImage: notes.template.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Generated \(notes.generatedAt, style: .relative) ago")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(notes.markdown, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)

                Button {
                    regenerateNotes()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                markdownContent(notes.markdown)
                    .padding(20)
                    .accessibilityIdentifier("notes.renderedMarkdown")
            }
        }
    }

    private func noNotesView(sessionID: String) -> some View {
        VStack(spacing: 16) {
            if let error = coordinator.notesEngine.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }

            if !loadedTranscript.isEmpty {
                // Transcript preview
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(loadedTranscript.prefix(20).enumerated()), id: \.offset) { _, record in
                            HStack(alignment: .top, spacing: 8) {
                                Text(record.speaker == .you ? "You" : "Them")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(record.speaker == .you ? .blue : .green)
                                    .frame(width: 35, alignment: .trailing)
                                Text(record.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                        }
                        if loadedTranscript.count > 20 {
                            Text("... and \(loadedTranscript.count - 20) more utterances")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 300)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Template picker for generation
            HStack {
                Picker("Template", selection: $selectedTemplateForGeneration) {
                    ForEach(coordinator.templateStore.templates) { template in
                        Label(template.name, systemImage: template.icon).tag(Optional(template))
                    }
                }
                .frame(maxWidth: 200)

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
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        // Final section
        if currentHeading != nil || !currentBody.isEmpty {
            sections.append(MarkdownSection(heading: currentHeading, level: currentLevel, body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return sections
    }

    // MARK: - Actions

    private func loadSelectedSession() {
        guard let sessionID = selectedSessionID else {
            loadedNotes = nil
            loadedTranscript = []
            return
        }

        Task {
            loadedNotes = await coordinator.sessionStore.loadNotes(sessionID: sessionID)
            loadedTranscript = await coordinator.sessionStore.loadTranscript(sessionID: sessionID)

            // Default template for generation
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

            // Save completed notes
            if !coordinator.notesEngine.generatedMarkdown.isEmpty {
                let notes = EnhancedNotes(
                    template: coordinator.templateStore.snapshot(of: template),
                    generatedAt: Date(),
                    markdown: coordinator.notesEngine.generatedMarkdown
                )
                await coordinator.sessionStore.saveNotes(sessionID: sessionID, notes: notes)
                loadedNotes = notes

                // Refresh history to update hasNotes
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

    private func regenerateNotes() {
        guard let sessionID = selectedSessionID else { return }
        loadedNotes = nil
        generateNotes(sessionID: sessionID)
    }
}
