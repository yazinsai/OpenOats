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
    public var audioFiles: [URL] { folder.map { f in Processing.roles.flatMap { f.trackFiles($0) } } ?? [] }
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
            case .needsAttention: .needsAttention(status.lastError ?? "Processing failed.")
            case .done: status.interrupted ? .interrupted : .done
            }
            return MeetingEntry(
                id: folder.id, title: file.flatMap { MeetingFileHeader(url: $0)?.title } ?? status.title
                    ?? MeetingFileWriter.fallbackTitle(status.startedAt),
                date: status.startedAt, duration: status.duration ?? status.endedAt.map { $0.timeIntervalSince(status.startedAt) },
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
    /// as unedited, so re-process still replaces it, and keeps the title.
    public func rename(_ entry: MeetingEntry, to title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var status = try entry.folder?.readStatus()
        status?.title = title
        if let old = entry.meetingFile, let data = try? Data(contentsOf: old) {
            let text = String(decoding: data, as: UTF8.self)
            var lines = text.components(separatedBy: "\n")
            var inFrontmatter = lines.first == "---"
            for i in lines.indices.dropFirst(inFrontmatter ? 1 : 0) {
                if inFrontmatter {
                    if lines[i] == "---" { inFrontmatter = false }
                    else if lines[i].hasPrefix("title:") { lines[i] = "title: \(MeetingFileWriter.quote(title))" }
                } else if lines[i].hasPrefix("# ") {
                    lines[i] = "# \(title)"
                    break
                }
            }
            let renamed = Data(lines.joined(separator: "\n").utf8)
            let name = old.deletingPathExtension().lastPathComponent
            let prefix = name.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}"#, options: .regularExpression).map { String(name[$0]) }
            let base = prefix.map { "\($0)-\(MeetingFileWriter.slug(title))" }
                ?? MeetingFileWriter.baseName(title: title, startedAt: status?.startedAt ?? entry.date)
            let folder = old.deletingLastPathComponent()
            let url = name == base ? old : MeetingFileWriter.freeURL(base: base, in: folder)
            try renamed.write(to: url, options: .atomic)
            if url != old { try FileManager.default.removeItem(at: old) }
            if status != nil {
                if status?.meetingFileHash == MeetingFileWriter.hash(data) { status?.meetingFileHash = MeetingFileWriter.hash(renamed) }
                status?.meetingFile = url.path
            }
        }
        if let status { try entry.folder?.writeStatus(status) }
    }

    /// Removes the Meeting file and the Meeting folder with its audio.
    public func delete(_ entry: MeetingEntry) throws {
        if let file = entry.meetingFile, FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if let folder = entry.folder { try FileManager.default.removeItem(at: folder.url) }
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
        let lines = head.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            // A dated file name from 1.x without frontmatter still counts.
            let dated = url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-\d{4}"#, options: .regularExpression) != nil
            if !dated { return nil }
            return
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
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
