import Foundation

/// Produces spec-compliant openoats/v1 Markdown exports from session data.
///
/// The writer is stateless: call `write(...)` with session metadata and transcript records,
/// and it returns the markdown output target. Exports are a single `.md` file by default,
/// but callers can request a package directory when session-local assets must be mirrored
/// alongside the markdown. All I/O is synchronous and runs on the caller's context
/// (designed for `nonisolated static` or actor-isolated use).
enum MarkdownMeetingWriter {

    // MARK: - Public API

    struct OutputTarget: Sendable {
        let markdownFileURL: URL
        let packageDirectoryURL: URL?
    }

    /// Metadata needed to produce the Markdown file, extracted from SessionIndex + sidecar.
    struct Metadata: Sendable {
        let sessionID: String
        let title: String?
        let startedAt: Date
        let endedAt: Date?
        let language: String?
        let meetingApp: String?
        let engine: String?

        init(from index: SessionIndex) {
            self.sessionID = index.id
            self.title = index.title
            self.startedAt = index.startedAt
            self.endedAt = index.endedAt
            self.language = index.language
            self.meetingApp = index.meetingApp
            self.engine = index.engine
        }
    }

    /// Write a spec-compliant Markdown export to the output directory.
    ///
    /// - Parameters:
    ///   - metadata: Session metadata (title, dates, app, engine).
    ///   - records: The transcript records from the JSONL session store.
    ///   - notesMarkdown: Optional LLM-generated notes markdown to include before the transcript.
    ///   - outputDirectory: The directory to write into (e.g. `~/Documents/OpenOats/`).
    /// - Returns: The written markdown target, or `nil` on failure.
    @discardableResult
    static func write(
        metadata: Metadata,
        records: [SessionRecord],
        notesMarkdown: String? = nil,
        outputDirectory: URL,
        preferPackage: Bool = false
    ) -> OutputTarget? {
        guard !records.isEmpty else {
            Log.markdownMeetingWriter.warning("MarkdownMeetingWriter: no records, skipping write")
            return nil
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Build the Markdown content
        let content = buildMarkdown(metadata: metadata, records: records, notesMarkdown: notesMarkdown)

        guard let target = resolveOutputTarget(
            metadata: metadata,
            directory: outputDirectory,
            preferPackage: preferPackage
        ) else {
            Log.markdownMeetingWriter.error("Failed to resolve markdown output target")
            return nil
        }
        let fileURL = target.markdownFileURL

        if let packageDirectoryURL = target.packageDirectoryURL {
            do {
                try fm.createDirectory(at: packageDirectoryURL, withIntermediateDirectories: true)
            } catch {
                Log.markdownMeetingWriter.error("Failed to create markdown package: \(error, privacy: .public)")
                return nil
            }
        }

        // Write with restricted permissions
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            Log.markdownMeetingWriter.info("Wrote meeting markdown: \(fileURL.lastPathComponent, privacy: .public)")
            return target
        } catch {
            Log.markdownMeetingWriter.error("Failed to write markdown: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Markdown Assembly

    static func buildMarkdown(metadata: Metadata, records: [SessionRecord], notesMarkdown: String? = nil) -> String {
        let resolvedTitle = metadata.title?.isEmpty == false ? metadata.title! : "Meeting"
        let frontmatter = buildFrontmatter(metadata: metadata, records: records, title: resolvedTitle)
        let body = buildBody(title: resolvedTitle, records: records, startedAt: metadata.startedAt, notesMarkdown: notesMarkdown)
        return frontmatter + "\n" + body
    }

    // MARK: - YAML Frontmatter

    static func buildFrontmatter(
        metadata: Metadata,
        records: [SessionRecord],
        title: String
    ) -> String {
        var lines: [String] = ["---"]

        lines.append("schema: openoats/v1")
        lines.append("title: \(yamlQuote(title))")
        lines.append("date: \(formatISO8601(metadata.startedAt))")
        lines.append("duration: \(computeDuration(records: records, metadata: metadata))")

        // Participants - derived from actual speakers in the transcript
        let speakerLabels: [String] = {
            var seen: [String] = []
            for r in records {
                let label = r.speaker.displayLabel
                if !seen.contains(label) { seen.append(label) }
            }
            return seen.isEmpty ? ["You", "Them"] : seen
        }()
        lines.append("participants:")
        for label in speakerLabels {
            lines.append("  - \(label)")
        }

        // Recorder (system user's full name)
        let recorderName = NSFullUserName()
        if !recorderName.isEmpty {
            lines.append("recorder: \(yamlQuote(recorderName))")
        }

        // Engine
        if let engine = metadata.engine, !engine.isEmpty {
            lines.append("engine: \(engine)")
        }

        // Language (BCP 47)
        if let language = metadata.language, !language.isEmpty {
            lines.append("language: \(language)")
        }

        // Meeting app (lowercase per spec)
        if let app = metadata.meetingApp, !app.isEmpty {
            lines.append("app: \(normalizeAppName(app))")
        }

        // Extension: link back to session ID
        lines.append("x_openoats_session: \(yamlQuote(metadata.sessionID))")

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: - Body

    static func buildBody(title: String, records: [SessionRecord], startedAt: Date, notesMarkdown: String? = nil) -> String {
        var parts: [String] = []

        // H1 title
        parts.append("# \(title)")
        parts.append("")

        // Notes section (if generated notes are available)
        if let notes = notesMarkdown, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## Notes")
            parts.append("")
            parts.append(notes.trimmingCharacters(in: .whitespacesAndNewlines))
            parts.append("")
        }

        // Transcript section
        parts.append("## Transcript")
        parts.append("")

        let transcriptLines = formatTranscriptLines(records: records, startedAt: startedAt)
        parts.append(transcriptLines)

        return parts.joined(separator: "\n")
    }

    // MARK: - Transcript Formatting

    static func formatTranscriptLines(records: [SessionRecord], startedAt: Date) -> String {
        var lines: [String] = []

        for record in records {
            let relativeTimestamp = formatRelativeTimestamp(
                record.timestamp,
                relativeTo: startedAt
            )
            let speaker = speakerLabel(record.speaker)
            let text = record.cleanedText ?? record.text
            lines.append("[\(relativeTimestamp)] **\(speaker):** \(text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Timestamp Helpers

    /// Format a date as a relative timestamp `HH:MM:SS` from the meeting start.
    static func formatRelativeTimestamp(_ timestamp: Date, relativeTo start: Date) -> String {
        let interval = max(0, timestamp.timeIntervalSince(start))
        let totalSeconds = Int(interval.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Format a date as ISO 8601 with timezone offset.
    static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    // MARK: - Duration

    /// Compute meeting duration in minutes from transcript records, rounded to nearest minute.
    /// Minimum is 1 minute.
    static func computeDuration(records: [SessionRecord], metadata: Metadata) -> Int {
        // Prefer endedAt from metadata if available
        if let endedAt = metadata.endedAt {
            let seconds = endedAt.timeIntervalSince(metadata.startedAt)
            return max(1, Int((seconds / 60.0).rounded()))
        }

        // Fallback: difference between first and last record timestamps
        guard let first = records.first, let last = records.last else { return 1 }
        let seconds = last.timestamp.timeIntervalSince(first.timestamp)
        return max(1, Int((seconds / 60.0).rounded()))
    }

    // MARK: - Speaker Label

    static func speakerLabel(_ speaker: Speaker) -> String {
        speaker.displayLabel
    }

    // MARK: - YAML Quoting

    /// Quote a YAML string value. Per spec, title MUST always be quoted.
    /// Wraps in double quotes and escapes internal double quotes and backslashes.
    static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    // MARK: - App Name Normalization

    /// Normalize meeting app display name to a lowercase slug for the `app` frontmatter field.
    /// Maps known display names to standard short names per spec.
    static func normalizeAppName(_ name: String) -> String {
        let lower = name.lowercased()
        // Map well-known display names to their spec identifiers
        if lower.contains("zoom") { return "zoom" }
        if lower.contains("teams") { return "teams" }
        if lower.contains("meet") && lower.contains("google") { return "meet" }
        if lower.contains("facetime") { return "facetime" }
        if lower.contains("slack") { return "slack" }
        if lower.contains("discord") { return "discord" }
        if lower.contains("webex") { return "webex" }
        if lower.contains("whatsapp") { return "whatsapp" }
        if lower.contains("tuple") { return "tuple" }
        if lower.contains("around") { return "around" }
        // Fallback: kebab-case the name
        return toKebabCase(lower)
    }

    // MARK: - Kebab Case

    /// Convert a string to kebab-case: lowercase, ASCII-only, hyphens for separators.
    /// Non-ASCII characters are stripped. Multiple hyphens are collapsed.
    /// Leading/trailing hyphens are trimmed.
    static func toKebabCase(_ input: String) -> String {
        let lowered = input.lowercased()

        // Replace non-alphanumeric ASCII with hyphens, strip non-ASCII
        var result = ""
        for scalar in lowered.unicodeScalars {
            if scalar.isASCII {
                let char = Character(scalar)
                if char.isLetter || char.isNumber {
                    result.append(char)
                } else {
                    result.append("-")
                }
            }
            // Non-ASCII characters are silently dropped
        }

        // Collapse multiple hyphens
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        // Trim leading/trailing hyphens
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Truncate to 60 characters per spec
        if result.count > 60 {
            result = String(result.prefix(60))
            // Don't end on a hyphen after truncation
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        // If nothing remains, use fallback
        return result.isEmpty ? "meeting" : result
    }

    // MARK: - Filename Generation

    /// Generate the filename: `YYYY-MM-DD-HHMM-kebab-title.md`
    /// Handles collisions by appending -2, -3, etc.
    static func resolveFilename(title: String?, startedAt: Date, directory: URL) -> URL {
        let baseName = resolveBaseName(title: title, startedAt: startedAt)
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).md")
        var counter = 2

        while fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: directory.appendingPathComponent(candidate.deletingPathExtension().lastPathComponent).path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter).md")
            counter += 1
        }

        return candidate
    }

    static func resolveOutputTarget(
        metadata: Metadata,
        directory: URL,
        preferPackage: Bool
    ) -> OutputTarget? {
        let fm = FileManager.default

        if let existing = findExistingOutputTarget(sessionID: metadata.sessionID, in: directory) {
            switch existing {
            case let .file(fileURL):
                if preferPackage {
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    let packageDirectoryURL = directory.appendingPathComponent(baseName, isDirectory: true)
                    do {
                        try fm.removeItem(at: fileURL)
                    } catch {
                        Log.markdownMeetingWriter.error("Failed to replace mirrored markdown file with package: \(error, privacy: .public)")
                        return nil
                    }
                    return OutputTarget(
                        markdownFileURL: packageDirectoryURL.appendingPathComponent("notes.md"),
                        packageDirectoryURL: packageDirectoryURL
                    )
                }

                return OutputTarget(markdownFileURL: fileURL, packageDirectoryURL: nil)

            case let .package(packageDirectoryURL):
                return OutputTarget(
                    markdownFileURL: packageDirectoryURL.appendingPathComponent("notes.md"),
                    packageDirectoryURL: packageDirectoryURL
                )
            }
        }

        let baseName = resolveBaseName(title: metadata.title, startedAt: metadata.startedAt)
        if preferPackage {
            let packageDirectoryURL = resolvePackageDirectory(baseName: baseName, directory: directory)
            return OutputTarget(
                markdownFileURL: packageDirectoryURL.appendingPathComponent("notes.md"),
                packageDirectoryURL: packageDirectoryURL
            )
        }

        return OutputTarget(
            markdownFileURL: resolveFilename(title: metadata.title, startedAt: metadata.startedAt, directory: directory),
            packageDirectoryURL: nil
        )
    }

    private enum ExistingOutputTarget {
        case file(URL)
        case package(URL)
    }

    private static func findExistingOutputTarget(sessionID: String, in directory: URL) -> ExistingOutputTarget? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for item in contents {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                let markdownURL = item.appendingPathComponent("notes.md")
                if fm.fileExists(atPath: markdownURL.path),
                   markdownContainsSessionID(markdownURL, sessionID: sessionID) {
                    return .package(item)
                }
                continue
            }

            if item.pathExtension == "md",
               markdownContainsSessionID(item, sessionID: sessionID) {
                return .file(item)
            }
        }

        return nil
    }

    private static func markdownContainsSessionID(_ url: URL, sessionID: String) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return content.contains("x_openoats_session: \(yamlQuote(sessionID))")
    }

    private static func resolveBaseName(title: String?, startedAt: Date) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd-HHmm"
        dateFmt.timeZone = TimeZone.current
        let datePrefix = dateFmt.string(from: startedAt)

        let titleSlug = toKebabCase(title ?? "meeting")
        return "\(datePrefix)-\(titleSlug)"
    }

    private static func resolvePackageDirectory(baseName: String, directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var counter = 2

        while fm.fileExists(atPath: candidate.path)
            || fm.fileExists(atPath: directory.appendingPathComponent("\(candidate.lastPathComponent).md").path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter)", isDirectory: true)
            counter += 1
        }

        return candidate
    }

}
