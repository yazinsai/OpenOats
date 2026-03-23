import Foundation
import os

private let writerLogger = Logger(subsystem: "com.openoats.app", category: "MarkdownMeetingWriter")

/// Produces spec-compliant openoats/v1 Markdown files from session data.
///
/// The writer is stateless: call `write(...)` with session metadata and transcript records,
/// and it returns the URL of the generated `.md` file. All I/O is synchronous and runs
/// on the caller's context (designed for `nonisolated static` or actor-isolated use).
enum MarkdownMeetingWriter {

    // MARK: - Public API

    /// Metadata needed to produce the Markdown file, extracted from SessionIndex + sidecar.
    struct Metadata: Sendable {
        let sessionID: String
        let title: String?
        let startedAt: Date
        let endedAt: Date?
        let meetingApp: String?
        let engine: String?

        init(from index: SessionIndex) {
            self.sessionID = index.id
            self.title = index.title
            self.startedAt = index.startedAt
            self.endedAt = index.endedAt
            self.meetingApp = index.meetingApp
            self.engine = index.engine
        }
    }

    /// Write a spec-compliant `.md` file to the output directory.
    ///
    /// - Parameters:
    ///   - metadata: Session metadata (title, dates, app, engine).
    ///   - records: The transcript records from the JSONL session store.
    ///   - outputDirectory: The directory to write into (e.g. `~/Documents/OpenOats/`).
    /// - Returns: The URL of the written file, or `nil` on failure.
    @discardableResult
    static func write(
        metadata: Metadata,
        records: [SessionRecord],
        outputDirectory: URL
    ) -> URL? {
        guard !records.isEmpty else {
            writerLogger.warning("MarkdownMeetingWriter: no records, skipping write")
            return nil
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Build the Markdown content
        let content = buildMarkdown(metadata: metadata, records: records)

        // Generate filename with collision handling
        let fileURL = resolveFilename(
            title: metadata.title,
            startedAt: metadata.startedAt,
            directory: outputDirectory
        )

        // Write with restricted permissions
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            writerLogger.info("Wrote meeting markdown: \(fileURL.lastPathComponent, privacy: .public)")
            return fileURL
        } catch {
            writerLogger.error("Failed to write markdown: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Markdown Assembly

    static func buildMarkdown(metadata: Metadata, records: [SessionRecord]) -> String {
        let resolvedTitle = metadata.title?.isEmpty == false ? metadata.title! : "Meeting"
        let frontmatter = buildFrontmatter(metadata: metadata, records: records, title: resolvedTitle)
        let body = buildBody(title: resolvedTitle, records: records, startedAt: metadata.startedAt)
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

    static func buildBody(title: String, records: [SessionRecord], startedAt: Date) -> String {
        var parts: [String] = []

        // H1 title
        parts.append("# \(title)")
        parts.append("")

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
            let text = record.refinedText ?? record.text
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
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd-HHmm"
        dateFmt.timeZone = TimeZone.current
        let datePrefix = dateFmt.string(from: startedAt)

        let titleSlug = toKebabCase(title ?? "meeting")
        let baseName = "\(datePrefix)-\(titleSlug)"

        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).md")
        var counter = 2

        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter).md")
            counter += 1
        }

        return candidate
    }

    // MARK: - Stage 3: Insert LLM Sections

    /// Insert LLM-generated sections (Summary, Action Items, Decisions) into an existing
    /// Stage 1+2 Markdown file. Updates frontmatter title and tags if provided.
    ///
    /// - Parameters:
    ///   - fileURL: The existing `.md` file to update.
    ///   - llmMarkdown: The raw LLM-generated markdown (may contain ## Summary, ## Action Items, ## Decisions).
    ///   - newTitle: An optional new title from the LLM.
    ///   - tags: Optional tags array from the LLM.
    /// - Returns: The (possibly renamed) URL of the updated file, or `nil` on failure.
    @discardableResult
    static func insertLLMSections(
        fileURL: URL,
        llmMarkdown: String,
        newTitle: String? = nil,
        tags: [String]? = nil
    ) -> URL? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            writerLogger.error("Failed to read file for LLM insertion: \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }

        // Parse frontmatter and body
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else {
            writerLogger.error("No valid frontmatter in file: \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }

        let bodyContent = parts.dropFirst(2).joined(separator: "---")
        let originalFrontmatterLines = parts[1].components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        let resolvedTitle = newTitle ?? extractTitle(from: originalFrontmatterLines)
        var updatedFrontmatter = rebuildFrontmatterWithUpdates(
            originalLines: originalFrontmatterLines,
            newTitle: newTitle,
            tags: tags
        )

        // Parse body to find ## Transcript
        let bodyLines = bodyContent.components(separatedBy: "\n")
        var transcriptStartIndex: Int?
        for (i, line) in bodyLines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "## Transcript" {
                transcriptStartIndex = i
                break
            }
        }

        // Build new body: # Title + LLM sections + ## Transcript
        var newBody: [String] = []
        newBody.append("# \(resolvedTitle ?? "Meeting")")
        newBody.append("")

        // Insert LLM-generated sections
        let llmSections = extractLLMSections(from: llmMarkdown)
        if !llmSections.isEmpty {
            newBody.append(llmSections)
            newBody.append("")
        }

        // Append transcript section (everything from ## Transcript onwards)
        if let transcriptStart = transcriptStartIndex {
            let transcriptContent = bodyLines[transcriptStart...].joined(separator: "\n")
            newBody.append(transcriptContent)
        }

        let finalContent = "---\n\(updatedFrontmatter)\n---\n\n\(newBody.joined(separator: "\n"))"

        // Write updated content
        do {
            try finalContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            writerLogger.error("Failed to write LLM sections: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Rename file if title changed
        if let newTitle, !newTitle.isEmpty {
            let directory = fileURL.deletingLastPathComponent()
            // Extract date from existing filename
            let existingName = fileURL.deletingPathExtension().lastPathComponent
            let datePrefix: String
            if existingName.count >= 15 {
                datePrefix = String(existingName.prefix(15)) // YYYY-MM-DD-HHMM
            } else {
                return fileURL
            }

            let newSlug = toKebabCase(newTitle)
            let newBaseName = "\(datePrefix)-\(newSlug)"
            var newURL = directory.appendingPathComponent("\(newBaseName).md")

            // Don't rename to self
            if newURL.lastPathComponent == fileURL.lastPathComponent {
                return fileURL
            }

            // Handle collision
            var counter = 2
            while FileManager.default.fileExists(atPath: newURL.path) {
                newURL = directory.appendingPathComponent("\(newBaseName)-\(counter).md")
                counter += 1
            }

            do {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
                writerLogger.info("Renamed meeting file to: \(newURL.lastPathComponent, privacy: .public)")
                return newURL
            } catch {
                writerLogger.warning("Failed to rename file: \(error.localizedDescription, privacy: .public)")
                return fileURL
            }
        }

        return fileURL
    }

    // MARK: - Stage 3 Helpers

    /// Extract the title from frontmatter lines.
    private static func extractTitle(from lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("title:") {
                var value = String(trimmed.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
                // Remove quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                    value = value.replacingOccurrences(of: "\\\\", with: "\u{0000}")
                    value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    value = value.replacingOccurrences(of: "\u{0000}", with: "\\")
                }
                return value
            }
        }
        return nil
    }

    /// Rebuild frontmatter with optional title and tags updates.
    private static func rebuildFrontmatterWithUpdates(
        originalLines: [String],
        newTitle: String?,
        tags: [String]?
    ) -> String {
        var result: [String] = []
        var insideParticipants = false
        var insideTags = false
        // Tags are re-inserted at the end after stripping originals

        for line in originalLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track multi-line YAML arrays
            if trimmed.hasPrefix("participants:") { insideParticipants = true; insideTags = false }
            else if trimmed.hasPrefix("tags:") { insideTags = true; insideParticipants = false }
            else if !trimmed.hasPrefix("- ") && !trimmed.isEmpty {
                insideParticipants = false
                insideTags = false
            }

            // Skip existing tags (we'll re-add them)
            if tags != nil && (trimmed.hasPrefix("tags:") || (insideTags && trimmed.hasPrefix("- "))) {
                continue
            }

            // Update title
            if let newTitle, trimmed.hasPrefix("title:") {
                result.append("title: \(yamlQuote(newTitle))")
                continue
            }

            result.append(line)
        }

        // Insert tags before the end
        if let tags, !tags.isEmpty {
            // Find a good insertion point (after recorder or engine, before closing ---)
            var insertIndex = result.count
            for (i, line) in result.enumerated().reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    insertIndex = i + 1
                    break
                }
            }
            var tagLines = ["tags:"]
            for tag in tags {
                tagLines.append("  - \(tag)")
            }
            result.insert(contentsOf: tagLines, at: insertIndex)
        }

        return result.joined(separator: "\n")
    }

    /// Extract ## Summary, ## Action Items, ## Decisions sections from LLM markdown.
    /// Returns the sections as a single string block ready for insertion.
    static func extractLLMSections(from markdown: String) -> String {
        // The LLM output might contain these sections mixed with other content.
        // We extract them in order: Summary, Action Items, Decisions.
        let lines = markdown.components(separatedBy: "\n")
        var sections: [String] = []
        var currentSection: [String]?
        var currentHeader: String?

        let knownHeaders = ["## Summary", "## Action Items", "## Decisions"]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if knownHeaders.contains(where: { trimmed.hasPrefix($0) }) {
                // Save previous section
                if let section = currentSection {
                    let content = section.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        sections.append(content)
                    }
                }
                currentSection = [line]
                currentHeader = trimmed
            } else if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                // End of a known section, hit an unknown heading
                if let section = currentSection {
                    let content = section.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        sections.append(content)
                    }
                }
                currentSection = nil
                currentHeader = nil
            } else if currentSection != nil {
                currentSection?.append(line)
            }
        }

        // Flush last section
        if let section = currentSection {
            let content = section.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append(content)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Patch Transcript Section

    /// Replace only the transcript section of an existing Markdown file,
    /// preserving frontmatter, title, and any LLM-generated sections.
    @discardableResult
    static func patchTranscriptSection(
        fileURL: URL,
        records: [SessionRecord]
    ) -> Bool {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            writerLogger.error("Failed to read file for transcript patch: \(fileURL.lastPathComponent, privacy: .public)")
            return false
        }

        let lines = content.components(separatedBy: "\n")

        // Find the "## Transcript" line
        guard let transcriptStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Transcript"
        }) else {
            writerLogger.warning("No ## Transcript section found in \(fileURL.lastPathComponent, privacy: .public)")
            return false
        }

        // Find the next ## heading after Transcript (if any)
        let afterTranscript = transcriptStart + 1
        let nextHeadingIndex = lines[afterTranscript...].firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("## ") && trimmed != "## Transcript"
        })

        // Extract the start date from frontmatter or first record
        let startedAt = records.first?.timestamp ?? Date()

        // Build new transcript lines
        let newTranscript = formatTranscriptLines(records: records, startedAt: startedAt)

        // Reconstruct: everything before ## Transcript + new transcript + everything after
        var result: [String] = Array(lines[..<transcriptStart])
        result.append("## Transcript")
        result.append("")
        result.append(newTranscript)

        if let nextIdx = nextHeadingIndex {
            result.append(contentsOf: lines[nextIdx...])
        }

        let finalContent = result.joined(separator: "\n")
        do {
            // Back up original before patching (batch transcript quality not yet validated at scale)
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("pre-batch.md")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)

            try finalContent.write(to: fileURL, atomically: true, encoding: .utf8)
            writerLogger.info("Patched transcript in \(fileURL.lastPathComponent, privacy: .public)")
            return true
        } catch {
            writerLogger.error("Failed to patch transcript: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Find Markdown File for Session

    /// Find the `.md` file for a given session ID in the output directory.
    /// Searches by the `x_openoats_session` frontmatter field.
    static func findMarkdownFile(sessionID: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if content.contains("x_openoats_session: \"\(sessionID)\"") {
                return file
            }
        }

        return nil
    }
}
