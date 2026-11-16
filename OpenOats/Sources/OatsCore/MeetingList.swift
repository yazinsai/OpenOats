import Foundation

/// One row of the window's meeting list: a Meeting folder (with its Meeting file once written) or a Meeting file
/// with no folder (carried over from 1.x).
public struct MeetingEntry: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case recording, processing, needsAttention(String), interrupted, done }

    public let id: String
    public var title: String
    public var date: Date
    public var duration: TimeInterval?
    public var state: State
    public var folder: MeetingFolder?
    public var meetingFile: URL?

    /// Mic, System or mixed track files kept in the Meeting folder.
    public var audioFiles: [URL] { folder.map { f in Track.allCases.flatMap { f.trackFiles($0) } } ?? [] }
    /// The duration in whole minutes, as the Meeting file's `duration` field gives it.
    public var minutes: Int? { duration.map(MeetingFileWriter.minutes) }
    /// Rename, Delete and Re-process wait until recording and Processing are over.
    public var isBusy: Bool { state == .recording || state == .processing || folder?.isBusy == true }
}

extension MeetingStore {
    /// Meeting folders plus the Meeting files in `notesFolder` no folder points at, newest first.
    public func entries(notesFolder: URL) -> [MeetingEntry] {
        var entries: [MeetingEntry] = list().compactMap { folder in
            guard let status = try? folder.readStatus() else { return nil }
            let file = status.meetingFile.map(URL.init(fileURLWithPath:)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let state: MeetingEntry.State = switch status.state {
            case .recording: .recording
            case .processing: .processing
            case .needsAttention: .needsAttention(status.lastError ?? "Needs attention: Processing didn't finish.")
            case .done: status.interrupted ? .interrupted : .done
            }
            return MeetingEntry(
                id: folder.id, title: file.flatMap { MeetingFileHeader(url: $0)?.title } ?? status.title
                    ?? MeetingFileWriter.fallbackTitle(status.startedAt),
                date: status.startedAt, duration: status.length,
                state: state, folder: folder, meetingFile: file)
        }
        let owned = Set(entries.compactMap { $0.meetingFile?.resolvingSymlinksInPath().path })
        let files = (try? FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "md" && !owned.contains(url.resolvingSymlinksInPath().path) {
            guard let header = MeetingFileHeader(url: url) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            entries.append(MeetingEntry(
                id: url.path, title: header.title ?? url.deletingPathExtension().lastPathComponent,
                date: header.date ?? mtime ?? .distantPast, duration: header.minutes.map { Double($0) * 60 },
                state: .done, meetingFile: url))
        }
        return entries.sorted { $0.date > $1.date }
    }

    /// Sets the title (frontmatter and H1) and renames the Meeting file to match. An unedited file stays recognised
    /// as unedited, so re-process still replaces it, and keeps the title. Throws `MeetingError.busy` while the
    /// Meeting is being recorded or processed.
    public func rename(_ entry: MeetingEntry, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let lock = try entry.folder?.lock()
        defer { withExtendedLifetime(lock) {} }
        var written: (url: URL, old: String, new: String)?
        if let old = entry.meetingFile, let data = try? Data(contentsOf: old) {
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            let fields = Frontmatter.fieldLines(lines)
            for i in fields ?? 0..<0 where lines[i].hasPrefix("title:") { lines[i] = "title: \(MeetingFileWriter.quote(title))" }
            if let h1 = lines[(fields.map { $0.upperBound + 1 } ?? 0)...].firstIndex(where: { $0.hasPrefix("# ") }) {
                lines[h1] = "# \(title)"
            }
            let renamed = Data(lines.joined(separator: "\n").utf8)
            let name = old.deletingPathExtension().lastPathComponent
            let prefix = name.range(of: MeetingFileWriter.datePrefix, options: .regularExpression).map { String(name[$0]) }
            let base = prefix.map { "\($0)-\(MeetingFileWriter.slug(title))" }
                ?? MeetingFileWriter.baseName(title: title, startedAt: entry.date)
            let url = name == base ? old : MeetingFileWriter.freeURL(base: base, in: old.deletingLastPathComponent())
            try renamed.write(to: url, options: .atomic)
            if url != old { try FileManager.default.removeItem(at: old) }
            written = (url, MeetingFileWriter.hash(data), MeetingFileWriter.hash(renamed))
        }
        try entry.folder?.updateStatus {
            $0.title = title
            guard let written else { return }
            if $0.meetingFileHash == written.old { $0.meetingFileHash = written.new }
            $0.meetingFile = written.url.path
        }
    }

    /// Removes the Meeting file and the Meeting folder with its audio. Throws `MeetingError.busy` while the Meeting
    /// is being recorded or processed.
    public func delete(_ entry: MeetingEntry) throws {
        let lock = try entry.folder.flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? try $0.lock() : nil }
        defer { withExtendedLifetime(lock) {} }
        if let file = entry.meetingFile, FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if let folder = entry.folder { try FileManager.default.removeItem(at: folder.url) }
    }
}

/// The frontmatter block at the head of a Meeting file: `---`, one `key: value` per line, `---`.
public enum Frontmatter {
    /// Indices of the lines between the two `---`; nil without frontmatter.
    static func fieldLines(_ lines: [String]) -> Range<Int>? {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return 1..<end
    }

    /// The Markdown after the frontmatter.
    public static func body(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let fields = fieldLines(lines) else { return markdown }
        return lines[(fields.upperBound + 1)...].joined(separator: "\n")
    }

    /// Top-level `key: value` fields (list items and nested lines skipped).
    static func fields(_ lines: [String]) -> [String: String]? {
        guard let range = fieldLines(lines) else { return nil }
        var fields: [String: String] = [:]
        for line in lines[range] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }
}

/// The few frontmatter fields the list shows, read from the head of a Meeting file. nil for other Markdown files.
struct MeetingFileHeader {
    var title: String?
    var date: Date?
    var minutes: Int?

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard let fields = Frontmatter.fields(head.components(separatedBy: "\n")) else {
            // A dated file name from 1.x without frontmatter still counts.
            if url.lastPathComponent.range(of: MeetingFileWriter.datePrefix, options: .regularExpression) == nil { return nil }
            return
        }
        guard fields["schema"]?.hasPrefix("openoats/") == true else { return nil }
        title = fields["title"].map(Self.unquote)
        date = fields["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
        minutes = fields["duration"].flatMap { Int($0) }
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
