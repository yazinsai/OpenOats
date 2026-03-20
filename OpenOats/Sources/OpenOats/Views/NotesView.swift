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
        case raw = "Raw"
        case refined = "Refined"
        case notes = "Notes"
    }

    @State private var detailViewMode: DetailViewMode = .raw
    @State private var isRefining = false
    @State private var refiningDone = 0

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
                    Button("") { detailViewMode = .raw }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("") { detailViewMode = .refined }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("") { detailViewMode = .notes }
                        .keyboardShortcut("3", modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        } else {
            ContentUnavailableView("Select a Session", systemImage: "doc.text", description: Text("Choose a session from the sidebar to view or generate notes."))
        }
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
            .frame(minWidth: 140, maxWidth: 280)
            .layoutPriority(1)

            Spacer(minLength: 4)

            // Refinement status (collapses at narrow widths)
            if detailViewMode == .refined {
                let progress = refinementProgress
                if isRefining {
                    ViewThatFits(in: .horizontal) {
                        Text("\(refiningDone)/\(progress.total) refining...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        EmptyView()
                    }
                    .layoutPriority(-1)
                } else if progress.total > 0 {
                    ViewThatFits(in: .horizontal) {
                        Group {
                            if progress.cleaned == progress.total {
                                Label("Refined", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else if progress.cleaned > 0 {
                                Text("\(progress.cleaned)/\(progress.total) refined")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // At narrow widths, hide entirely
                        EmptyView()
                    }
                    .layoutPriority(-1)
                }
            }

            // Notes metadata (first to hide at narrow widths)
            if detailViewMode == .notes, let notes = loadedNotes {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Label(notes.template.name, systemImage: notes.template.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Generated \(notes.generatedAt, style: .relative) ago")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    // Medium: just the template name
                    Label(notes.template.name, systemImage: notes.template.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Narrow: hide metadata entirely
                    EmptyView()
                }
                .layoutPriority(-1)
            }

            // Copy button (icon-only to save space)
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

            // Regenerate (split button: click = same template, chevron = pick template)
            if detailViewMode == .notes && loadedNotes != nil {
                Menu {
                    ForEach(coordinator.templateStore.templates) { template in
                        Button {
                            regenerateNotes(with: template)
                        } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                        .disabled(loadedNotes?.template.id == template.id)
                    }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                } primaryAction: {
                    regenerateNotes()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Regenerate notes (click) or pick a different template (arrow)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func detailBody(sessionID: String) -> some View {
        ZStack {
            rawTranscriptView
                .zIndex(detailViewMode == .raw ? 1 : 0)
                .opacity(detailViewMode == .raw ? 1 : 0)
                .allowsHitTesting(detailViewMode == .raw)
                .accessibilityHidden(detailViewMode != .raw)

            refinedTranscriptView
                .zIndex(detailViewMode == .refined ? 1 : 0)
                .opacity(detailViewMode == .refined ? 1 : 0)
                .allowsHitTesting(detailViewMode == .refined)
                .accessibilityHidden(detailViewMode != .refined)

            notesTab(sessionID: sessionID)
                .zIndex(detailViewMode == .notes ? 1 : 0)
                .opacity(detailViewMode == .notes ? 1 : 0)
                .allowsHitTesting(detailViewMode == .notes)
                .accessibilityHidden(detailViewMode != .notes)
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
                        .scaleEffect(0.8)
                    Text("Generating notes...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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

    private func notesContentView(_ notes: EnhancedNotes) -> some View {
        ScrollView {
            markdownContent(notes.markdown)
                .padding(20)
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
        }
    }

    // MARK: - Transcript Views

    @ViewBuilder
    private func transcriptList(refined: Bool) -> some View {
        if loadedTranscript.isEmpty {
            ContentUnavailableView("No Transcript", systemImage: "waveform", description: Text("This session has no recorded utterances."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(loadedTranscript.enumerated()), id: \.offset) { _, record in
                        transcriptRow(record: record, refined: refined)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var rawTranscriptView: some View {
        transcriptList(refined: false)
    }

    @ViewBuilder
    private var refinedTranscriptView: some View {
        if loadedTranscript.isEmpty {
            transcriptList(refined: true)
        } else if refinementProgress.cleaned == 0 && !isRefining {
            ContentUnavailableView {
                Label("Refine This Transcript", systemImage: "wand.and.stars")
            } description: {
                Text("Remove filler words and fix grammar while keeping the original meaning.")
            } actions: {
                Button {
                    refineLoadedTranscript()
                } label: {
                    Label("Refine Now", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
        } else if isRefining {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Refining transcript...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcriptList(refined: true)
        }
    }

    @ViewBuilder
    private func transcriptRow(record: SessionRecord, refined: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.speaker == .you ? "You" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(record.speaker == .you ? Color.youColor : Color.themColor)
                .frame(width: 36, alignment: .trailing)

            if refined, let refinedText = record.refinedText {
                Text(refinedText)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else if refined {
                HStack(spacing: 4) {
                    Text(record.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Not yet refined")
                }
            } else {
                Text(record.text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var copyContentIsEmpty: Bool {
        switch detailViewMode {
        case .raw, .refined:
            return loadedTranscript.isEmpty
        case .notes:
            return loadedNotes == nil
        }
    }

    private var refinementProgress: (cleaned: Int, total: Int) {
        let total = loadedTranscript.count
        let cleaned = loadedTranscript.filter { $0.refinedText != nil }.count
        return (cleaned, total)
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

    private func copyCurrentContent() {
        let text: String
        switch detailViewMode {
        case .raw, .refined:
            let useRefined = detailViewMode == .refined
            text = loadedTranscript.map { record in
                let label = record.speaker == .you ? "You" : "Them"
                let content = useRefined ? (record.refinedText ?? record.text) : record.text
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

        // Clear immediately to prevent stale content flash
        loadedNotes = nil
        loadedTranscript = []

        Task {
            let notes = await coordinator.sessionStore.loadNotes(sessionID: sessionID)
            let transcript = await coordinator.sessionStore.loadTranscript(sessionID: sessionID)

            // Guard against rapid session switching
            guard selectedSessionID == sessionID else { return }

            loadedNotes = notes
            loadedTranscript = transcript
            detailViewMode = notes != nil ? .notes : .raw

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

    private func refineLoadedTranscript() {
        guard let sessionID = selectedSessionID, !loadedTranscript.isEmpty else { return }
        isRefining = true
        refiningDone = 0

        Task {
            defer { isRefining = false }

            let utterances = loadedTranscript.map { record in
                Utterance(text: record.text, speaker: record.speaker, timestamp: record.timestamp)
            }

            let tempStore = TranscriptStore()
            await MainActor.run {
                for u in utterances {
                    tempStore.append(u)
                }
            }

            let engine = TranscriptRefinementEngine(settings: settings, transcriptStore: tempStore)
            for u in utterances {
                await engine.refine(u)
                refiningDone += 1
            }
            await engine.drain(timeout: .seconds(60))

            let refinedUtterances = await MainActor.run { tempStore.utterances }
            await coordinator.sessionStore.backfillRefinedText(sessionID: sessionID, from: refinedUtterances)

            guard selectedSessionID == sessionID else { return }
            loadedTranscript = await coordinator.sessionStore.loadTranscript(sessionID: sessionID)
        }
    }
}

// MARK: - SessionRecord stable identity for ForEach

extension SessionRecord {
    var stableID: String {
        "\(timestamp.timeIntervalSinceReferenceDate)-\(speaker)"
    }
}
