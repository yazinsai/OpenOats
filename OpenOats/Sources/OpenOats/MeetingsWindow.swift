import AppKit
import OatsCore
import SwiftUI

/// The window: the meeting list on the left, the rendered Meeting file on the right. Drop an audio file to import it.
struct MeetingsWindow: View {
    @ObservedObject var model: AppModel
    @State private var entries: [MeetingEntry] = []
    @State private var renaming: MeetingEntry.ID?
    @State private var deleting: MeetingEntry?
    @State private var problem: String?
    @State private var dropping = false
    @FocusState private var listFocused: Bool
    @Namespace private var selection

    private var notesFolder: URL { model.settings.load().notesFolder }
    private var selected: MeetingEntry? { entries.first { $0.id == model.selection } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 296)
            Theme.line.frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        }
        .background(Theme.sidebar)
        .ignoresSafeArea()
        .frame(minWidth: 680, minHeight: 440)
        .overlay { if dropping { DropTarget().transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))) } }
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) } isTargeted: { targeted in
            withAnimation(Theme.snappy) { dropping = targeted }
        }
        .onAppear {
            refresh()
            listFocused = true
        }
        .onReceive(model.objectWillChange) { DispatchQueue.main.async { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .confirmationDialog("Delete this Meeting?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) { if let entry = deleting { perform { try model.store.delete(entry) } } }
        } message: {
            Text("The Meeting file and its audio are deleted.")
        }
        .alert(problem ?? "", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {}
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings").font(Theme.heading).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                Spacer()
                if !entries.isEmpty { Text("\(entries.count)").font(Theme.meta).monospacedDigit().foregroundStyle(Theme.ink3) }
            }
            .padding(.horizontal, Theme.s5).padding(.top, 44).padding(.bottom, Theme.s3)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        ForEach(Self.days(entries), id: \.0) { day, rows, recent in
                            Section {
                                ForEach(rows) { row($0, recent: recent) }
                            } header: {
                                Text(day).font(Theme.eyebrow).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.ink3)
                                    .padding(.horizontal, Theme.s3).padding(.top, Theme.s3).padding(.bottom, Theme.s1 + 2)
                                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.s3).padding(.bottom, Theme.s4)
                    .animation(Theme.gentle, value: entries)
                }
                .onChange(of: model.selection) { _, id in withAnimation(Theme.snappy) { proxy.scrollTo(id) } }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard let i = entries.firstIndex(where: { $0.id == model.selection }) else { return }
                let next = direction == .up ? i - 1 : direction == .down ? i + 1 : i
                if entries.indices.contains(next) { select(entries[next]) }
            }
            .onKeyPress(.return) { selected.map { beginRename($0) } != nil ? .handled : .ignored }
            .onDeleteCommand { if let entry = selected, !entry.isBusy { deleting = entry } }
            .overlay {
                if entries.isEmpty {
                    Text("Your Meetings will appear here.").font(Theme.meta).foregroundStyle(Theme.ink3).padding(Theme.s5)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetings.list")
    }

    private func row(_ entry: MeetingEntry, recent: Bool) -> some View {
        MeetingRow(entry: entry, recent: recent, selected: entry.id == model.selection, focused: listFocused, namespace: selection)
            .id(entry.id)
            .onTapGesture { select(entry) }
            .contextMenu { actions(entry) }
            .accessibilityAction { select(entry) }
            .transition(Theme.rise)
    }

    private func select(_ entry: MeetingEntry) {
        listFocused = true
        if renaming != entry.id { renaming = nil }
        withAnimation(Theme.snappy) { model.selection = entry.id }
    }

    /// Rows grouped under Today, Yesterday, a weekday of the last week (`recent`: rows show only the time), or the month.
    static func days(_ entries: [MeetingEntry]) -> [(String, [MeetingEntry], Bool)] {
        let calendar = Calendar.current
        let weekAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: .now)!)
        var groups: [(String, [MeetingEntry], Bool)] = []
        for entry in entries {
            let date = entry.date, recent = date >= weekAgo
            let day = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday"
                : recent ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.wide).year())
            if groups.last?.0 == day { groups[groups.count - 1].1.append(entry) } else { groups.append((day, [entry], recent)) }
        }
        return groups
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if entries.isEmpty {
            EmptyMeetings(hotkey: Hotkey.saved?.label, start: model.recorder == nil ? { model.start() } : nil)
        } else if let entry = selected {
            MeetingDetail(
                entry: entry, recording: model.recorder?.folder.id == entry.id, renaming: renaming == entry.id,
                rename: { title in
                    guard renaming == entry.id else { return }
                    renaming = nil
                    if let title, title != entry.title { perform { try model.store.rename(entry, to: title) } }
                },
                retry: { retry(entry) }, stop: { model.stop() }
            ) { actions(entry) }
            .id(entry.id)
            .transition(.opacity)
        } else {
            Text("Select a Meeting").font(Theme.ui).foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder private func actions(_ entry: MeetingEntry) -> some View {
        let file = entry.meetingFile
        let audio = entry.audioFiles
        let busy = entry.isBusy
        Button("Rename…") { beginRename(entry) }.disabled(busy)
        Button("Copy") { Self.copy(file) }.disabled(file == nil)
        Button("Open in Editor") { file.map { _ = NSWorkspace.shared.open($0) } }.disabled(file == nil)
        Button("Show in Finder") { file.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }.disabled(file == nil)
        Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(audio) }.disabled(audio.isEmpty)
        Divider()
        if case .needsAttention = entry.state { Button("Retry") { retry(entry) } }
        Button("Re-process") { perform { try model.reprocess(entry) } }.disabled(entry.folder == nil || audio.isEmpty || busy)
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }.disabled(busy)
    }

    private func beginRename(_ entry: MeetingEntry) {
        guard !entry.isBusy else { return }
        model.selection = entry.id
        renaming = entry.id
    }

    private func refresh() {
        let fresh = model.store.entries(notesFolder: notesFolder)
        if fresh != entries { entries = fresh }
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

    @discardableResult static func copy(_ file: URL?) -> Bool {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        perform { try model.importAudio(urls) }
        return problem == nil
    }
}

struct MeetingRow: View {
    let entry: MeetingEntry
    let recent: Bool
    let selected: Bool
    let focused: Bool
    let namespace: Namespace.ID
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(Theme.uiStrong).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            HStack(spacing: Theme.s1 + 2) {
                Text(entry.date.formatted(recent ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute())).fixedSize()
                if let minutes = entry.minutes { Text("·").foregroundStyle(Theme.ink3).accessibilityHidden(true); Text("\(minutes) min").fixedSize() }
                Spacer(minLength: 0)
                StateBadge(state: entry.state).fixedSize().layoutPriority(1)
            }
            .font(Theme.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            if case .needsAttention(let reason) = entry.state {
                Text(reason).font(Theme.meta).foregroundStyle(Theme.ink2).lineLimit(2).padding(.top, 1)
            }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2 + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.r2, style: .continuous)
                    .fill(focused ? Theme.accent.opacity(0.14) : Theme.ink.opacity(0.07))
                    // One shared highlight slides between rows; with Reduce Motion each row has its own, so it fades.
                    .matchedGeometryEffect(id: Theme.reduceMotion ? entry.id : "selection", in: namespace)
            } else if hover {
                RoundedRectangle(cornerRadius: Theme.r2, style: .continuous).fill(Theme.ink.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.fade, value: hover)
        .animation(Theme.gentle, value: entry.state)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The state beside a row's time: a glyph and a word, never colour alone. Nothing for a finished Meeting.
struct StateBadge: View {
    let state: MeetingEntry.State

    var body: some View {
        if let label = state.label {
            Label {
                Text(label)
            } icon: {
                if state == .recording { Circle().fill(state.color).frame(width: 6, height: 6) } else { Image(systemName: state.symbol) }
            }
            .labelStyle(Tight())
            .font(Theme.meta.weight(.medium)).foregroundStyle(state.color)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private struct Tight: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: Theme.s1) { configuration.icon.imageScale(.small); configuration.title }
        }
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

    var symbol: String {
        switch self {
        case .processing: "circle.dotted.circle"
        case .needsAttention: "exclamationmark.triangle.fill"
        default: "bolt.horizontal.circle"
        }
    }

    var color: Color {
        switch self {
        case .recording: Theme.recording
        case .processing: Theme.accent
        case .needsAttention: Theme.attention
        case .interrupted: Theme.interrupted
        case .done: Theme.ink2
        }
    }
}

struct MeetingDetail<Actions: View>: View {
    let entry: MeetingEntry
    let recording: Bool
    let renaming: Bool
    let rename: (String?) -> Void
    let retry: () -> Void
    let stop: () -> Void
    @ViewBuilder let actions: () -> Actions
    /// The Meeting file, read once per file and state change rather than on every render.
    @State private var file: MeetingFileView?
    @State private var draft = ""
    @State private var copied = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, Theme.s5)
                banner
                if let file {
                    file.transition(.opacity)
                } else {
                    placeholder.frame(maxWidth: .infinity).padding(.top, Theme.s7).transition(.opacity)
                }
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .padding(.horizontal, Theme.s6).padding(.top, 72).padding(.bottom, Theme.s8)
            .frame(maxWidth: .infinity)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)], startPoint: .top, endPoint: .bottom)
            .padding(.top, -4))
        .overlay(alignment: .topTrailing) { toolbar.padding(.top, Theme.s3).padding(.trailing, Theme.s4) }
        .animation(Theme.gentle, value: entry.state)
        .animation(Theme.gentle, value: file == nil)
        .task(id: entry) {
            file = entry.meetingFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { MeetingFileView(markdown: $0, title: entry.title) }
        }
        .onChange(of: renaming, initial: true) { _, on in
            guard on else { return }
            draft = entry.title
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(spacing: Theme.s2) {
                Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                if let minutes = entry.minutes { Text("·").accessibilityHidden(true); Text("\(minutes) min") }
            }
            .font(Theme.meta).foregroundStyle(Theme.ink2)
            if renaming {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain).font(Theme.title).foregroundStyle(Theme.ink)
                    .focused($titleFocused)
                    .onSubmit { rename(draft) }
                    .onExitCommand { rename(nil) }
                    .onChange(of: titleFocused) { _, focused in if !focused { rename(draft) } }
                    .overlay(alignment: .bottom) { Capsule().fill(Theme.accent).frame(height: 2).offset(y: 4) }
            } else {
                Text(entry.title).font(Theme.title).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder private var banner: some View {
        switch entry.state {
        case .needsAttention(let reason):
            Notice(tint: Theme.attention, symbol: "exclamationmark.triangle.fill", title: "Needs attention", detail: reason) {
                Button("Retry", action: retry).buttonStyle(PillButtonStyle(tint: Theme.attention))
            }
        case .interrupted:
            Notice(tint: Theme.interrupted, symbol: "bolt.horizontal.circle", title: "Interrupted",
                   detail: "The recording ended without Stop, so the end of this Meeting may be missing.") { EmptyView() }
        case .processing where file != nil:
            Notice(tint: Theme.accent, symbol: "circle.dotted.circle", title: "Processing",
                   detail: "This Meeting file is replaced when Processing finishes.") { EmptyView() }
        default: EmptyView()
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: Theme.s3) {
            switch entry.state {
            case .recording:
                Circle().fill(Theme.recording).frame(width: 12, height: 12)
                    .background(Circle().fill(Theme.recording.opacity(0.15)).frame(width: 32, height: 32))
                    .padding(.bottom, Theme.s2)
                Text(entry.date, style: .timer).font(Theme.clock).foregroundStyle(Theme.ink)
                Text("Recording. The Meeting file appears here after you stop.").font(Theme.ui).foregroundStyle(Theme.ink2)
                if recording {
                    Button("Stop Recording", action: stop).buttonStyle(PillButtonStyle(tint: Theme.recording)).padding(.top, Theme.s2)
                }
            case .processing:
                ProcessingBar(running: true).frame(width: 160).padding(.bottom, Theme.s2)
                Text("Processing").font(Theme.display).foregroundStyle(Theme.ink)
                Text("Transcribing the Mic and System tracks. The Meeting file appears here when it's ready.")
                    .font(Theme.ui).foregroundStyle(Theme.ink2)
            case .needsAttention:
                Text("No Meeting file yet. Retry picks up where Processing stopped.").font(Theme.ui).foregroundStyle(Theme.ink3)
            default:
                Text("The Meeting file isn't in your notes folder.").font(Theme.ui).foregroundStyle(Theme.ink3)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button {
                copyFile()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
            .help("Copy the Meeting file").accessibilityLabel(copied ? "Copied" : "Copy the Meeting file")
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(entry.meetingFile == nil)
            Button { entry.meetingFile.map { _ = NSWorkspace.shared.open($0) } } label: { Image(systemName: "square.and.pencil") }
                .help("Open in Editor").accessibilityLabel("Open in Editor")
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(entry.meetingFile == nil)
            Button { entry.meetingFile.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").accessibilityLabel("Show in Finder")
                .disabled(entry.meetingFile == nil)
            Menu { actions() } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .help("More actions").accessibilityLabel("More actions")
        }
        .buttonStyle(QuietButtonStyle(square: true))
        .foregroundStyle(Theme.ink2)
    }

    private func copyFile() {
        guard MeetingsWindow.copy(entry.meetingFile) else { return }
        withAnimation(Theme.lively) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.gentle) { copied = false }
        }
    }
}

/// A tinted banner above the Meeting file: Needs attention, Interrupted, Processing again.
struct Notice<Trailing: View>: View {
    let tint: Color
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: symbol).font(Theme.ui).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.uiStrong).foregroundStyle(tint)
                Text(detail).font(Theme.ui).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.s2)
            trailing()
        }
        .padding(Theme.s4)
        .card(tint, radius: Theme.r3)
        .padding(.bottom, Theme.s6)
        .accessibilityElement(children: .contain)
        .transition(Theme.rise)
    }
}

/// No Meetings yet: what to do first.
struct EmptyMeetings: View {
    let hotkey: String?
    let start: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.s4) {
            OatMark(size: 56).padding(.bottom, Theme.s2)
            Text("No Meetings yet").font(Theme.display).foregroundStyle(Theme.ink)
            Text("Start recording from the menu bar, or drop an audio file anywhere in this window to import it.")
                .font(Theme.ui).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 320)
            if let start {
                Button("Start Recording", action: start).buttonStyle(PillButtonStyle()).padding(.top, Theme.s2)
            }
            if let hotkey {
                Text("or press \(hotkey) anywhere").font(Theme.meta).foregroundStyle(Theme.ink3)
            }
        }
        .padding(Theme.s6)
    }
}

/// Shown while a file is dragged over the window.
struct DropTarget: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Theme.canvas.opacity(0.8)
            RoundedRectangle(cornerRadius: Theme.r3, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: Theme.r3, style: .continuous).fill(Theme.accent.opacity(0.04)))
                .padding(.horizontal, Theme.s4).padding(.bottom, Theme.s4).padding(.top, 36)
            VStack(spacing: Theme.s3) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 28, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64).background(Circle().fill(Theme.accent.opacity(0.12)))
                Text("Drop to import").font(Theme.display).foregroundStyle(Theme.ink)
                Text("One audio file becomes a new Meeting.").font(Theme.ui).foregroundStyle(Theme.ink2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
