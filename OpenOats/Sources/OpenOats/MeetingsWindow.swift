import AppKit
import OatsCore
import SwiftUI

/// The window: the meeting list on the left, the rendered Meeting file on the right. Drop an audio file to import it.
struct MeetingsWindow: View {
    @ObservedObject var model: AppModel
    @State private var entries: [MeetingEntry] = []
    @State private var renaming: MeetingEntry?
    @State private var newTitle = ""
    @State private var deleting: MeetingEntry?
    @State private var problem: String?

    private var notesFolder: URL { model.settings.load().notesFolder }
    private var selected: MeetingEntry? { entries.first { $0.id == model.selection } }

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $model.selection) { entry in
                MeetingRow(entry: entry).contextMenu { actions(entry) }
            }
            .accessibilityIdentifier("meetings.list")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if entries.isEmpty { Text("No Meetings yet. Record one from the menu bar, or drop an audio file here.").multilineTextAlignment(.center).foregroundStyle(.secondary).padding() }
            }
        } detail: {
            if let entry = selected { MeetingDetail(entry: entry, retry: { retry(entry) }).id(entry.id) } else { Text("Select a Meeting").foregroundStyle(.secondary) }
        }
        .toolbar {
            if let entry = selected { Menu { actions(entry) } label: { Label("Actions", systemImage: "ellipsis.circle") } }
        }
        .frame(minWidth: 640, minHeight: 400)
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) }
        .onAppear(perform: refresh)
        .onReceive(model.objectWillChange) { DispatchQueue.main.async { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .alert("Rename Meeting", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let entry = renaming { perform { try model.store.rename(entry, to: newTitle) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this Meeting?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) { if let entry = deleting { perform { try model.store.delete(entry) } } }
        } message: {
            Text("The Meeting file and its audio are deleted.")
        }
        .alert(problem ?? "", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {}
    }

    @ViewBuilder private func actions(_ entry: MeetingEntry) -> some View {
        let file = entry.meetingFile
        let audio = entry.audioFiles
        let busy = entry.isBusy
        Button("Rename…") { newTitle = entry.title; renaming = entry }.disabled(busy)
        Button("Copy") { copy(file) }.disabled(file == nil)
        Button("Open in Editor") { file.map { _ = NSWorkspace.shared.open($0) } }.disabled(file == nil)
        Button("Show in Finder") { file.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }.disabled(file == nil)
        Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(audio) }.disabled(audio.isEmpty)
        Divider()
        if case .needsAttention = entry.state { Button("Retry") { retry(entry) } }
        Button("Re-process") { perform { try model.reprocess(entry) } }.disabled(entry.folder == nil || audio.isEmpty || busy)
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }.disabled(busy)
    }

    private func refresh() {
        entries = model.store.entries(notesFolder: notesFolder)
        if model.selection == nil || selected == nil { model.selection = entries.first?.id }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { problem = error.localizedDescription }
        refresh()
    }

    private func retry(_ entry: MeetingEntry) {
        if let folder = entry.folder { model.enqueue(folder) }
        refresh()
    }

    private func copy(_ file: URL?) {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        perform { try model.importAudio(urls) }
        return problem == nil
    }
}

struct MeetingRow: View {
    let entry: MeetingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                if let minutes = entry.minutes { Text("\(minutes) min") }
                if let label = entry.state.label { Text(label).foregroundStyle(entry.state.color) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension MeetingEntry.State {
    var label: String? {
        switch self {
        case .recording: "Recording"
        case .processing: "Processing"
        case .needsAttention: "Needs attention"
        case .interrupted: "Interrupted"
        case .done: nil
        }
    }

    var color: Color {
        switch self {
        case .recording: .red
        case .needsAttention: .orange
        default: .secondary
        }
    }
}

struct MeetingDetail: View {
    let entry: MeetingEntry
    let retry: () -> Void
    /// The Meeting file, read once per file and state change rather than on every render.
    @State private var markdown: MarkdownView?

    var body: some View {
        Group {
            if let markdown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if case .needsAttention(let reason) = entry.state { attention(reason).padding(.bottom, 12) }
                        markdown
                    }
                    .padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    switch entry.state {
                    case .recording: Text("Recording…")
                    case .needsAttention(let reason): attention(reason)
                    default: Text("Processing…")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: entry) {
            markdown = entry.meetingFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(MarkdownView.init)
        }
    }

    private func attention(_ reason: String) -> some View {
        HStack {
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Retry", action: retry)
        }
    }
}

/// A light Markdown renderer for Meeting files: frontmatter dropped, headings, lists, quotes, code and paragraphs.
struct MarkdownView: View {
    enum Block { case heading(Int, String), item(String, String), quote(String), code(String), paragraph(String) }

    let blocks: [Block]

    init(markdown: String) { blocks = Self.parse(markdown) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { i in
                switch blocks[i] {
                case let .heading(level, text):
                    Text(Self.inline(text)).font(level == 1 ? .title.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, level == 1 ? 0 : 8)
                case let .item(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(marker); Text(Self.inline(text)) }
                case let .quote(text): Text(Self.inline(text)).foregroundStyle(.secondary).padding(.leading, 10)
                case let .code(text): Text(text).font(.body.monospaced())
                case let .paragraph(text): Text(Self.inline(text))
                }
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func parse(_ markdown: String) -> [Block] {
        let lines = Frontmatter.body(markdown).components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes != trimmed.startIndex, trimmed[hashes] == " " {
                flush()
                blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...].dropFirst())))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                let indent = String(repeating: "    ", count: (line.count - line.drop { $0 == " " }.count) / 2)
                blocks.append(.item(indent + "•", String(trimmed.dropFirst(2))))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), dot != trimmed.startIndex,
                      trimmed[dot...].hasPrefix(". ") {
                flush()
                blocks.append(.item(String(trimmed[...dot]), String(trimmed[dot...].dropFirst(2))))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}
