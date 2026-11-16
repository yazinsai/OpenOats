import CryptoKit
import Foundation

/// Builds and names the Meeting file (docs/meeting-format-spec.md, trimmed from 1.x `MarkdownMeetingWriter`).
enum MeetingFileWriter {
    struct Content {
        var meetingID: String
        var title: String?
        var startedAt: Date
        var duration: TimeInterval
        var language: String?
        var engine: String?
        var interrupted: Bool
        var notes: String?
        var turns: [Turn]
    }

    /// Title when the Notes backend gave none: the Meeting's date and time.
    static func fallbackTitle(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func markdown(_ c: Content) -> String {
        let title = c.title ?? fallbackTitle(c.startedAt)
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let speakers = c.turns.reduce(into: [String]()) { seen, turn in
            if let s = turn.speaker, !seen.contains(s) { seen.append(s) }
        }
        var lines = [
            "---", "schema: openoats/v1", "title: \(quote(title))", "date: \(iso.string(from: c.startedAt))",
            "duration: \(max(1, Int((c.duration / 60).rounded())))",
        ]
        lines.append(speakers.isEmpty ? "participants: []" : "participants:")
        lines += speakers.map { "  - \($0)" }
        if let language = c.language { lines.append("language: \(language)") }
        if let engine = c.engine { lines.append("engine: \(engine)") }
        if c.interrupted { lines.append("interrupted: true") }
        lines += ["x_openoats_meeting: \(quote(c.meetingID))", "---", "", "# \(title)", ""]
        if let notes = c.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines += [notes, ""]
        }
        lines += ["## Transcript", ""]
        for turn in c.turns {
            let label = turn.speaker.map { " **\($0):**" } ?? ""
            lines += ["[\(timestamp(turn.start))]\(label) \(turn.text)", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// `YYYY-MM-DD-HHMM-kebab-title.md`; slug `meeting` when there is no Notes title.
    static func baseName(title: String?, startedAt: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(f.string(from: startedAt))-\(slug(title ?? ""))"
    }

    /// First free `<base>.md`, `<base>-2.md`, … in `folder`.
    static func freeURL(base: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return url
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars where scalar.isASCII {
            let c = Character(scalar)
            out.append(c.isLetter || c.isNumber ? c : "-")
        }
        let parts = out.split(separator: "-")
        var result = ""
        for part in parts where result.count + part.count + 1 <= 60 {
            result += result.isEmpty ? String(part) : "-\(part)"
        }
        return result.isEmpty ? "meeting" : result
    }
}
