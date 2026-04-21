import AppKit
import Foundation

/// Exports meeting notes to Apple Notes.app via AppleScript.
///
/// Notes are created (or updated) in a dedicated folder inside the user's
/// first Notes account. The note title follows a deterministic format
/// `[OpenOats] YYYY-MM-DD <meeting title>` so re-exports always overwrite the
/// same note rather than creating duplicates.
///
/// NSAppleScript must execute on the main thread — all paths that reach
/// `runExport` use `DispatchQueue.main.async` to guarantee this without
/// blocking the caller.
enum AppleNotesService {

    // MARK: - Public API

    /// Request Automation permission for Notes.app by sending a trivial Apple Event.
    ///
    /// Call this when the user enables the integration so macOS shows the
    /// permission dialog immediately rather than mid-export. Returns `true` if
    /// permission was granted (or was already granted).
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            // NSAppleScript requires the main thread; the permission dialog
            // only appears when the Apple Event is sent from the main thread.
            // "count every account" is the lightest real query that forces
            // Notes.app to receive an Apple Event and trigger the dialog.
            DispatchQueue.main.async {
                var errorDict: NSDictionary?
                NSAppleScript(source: """
                    tell application "Notes"
                        count every account
                    end tell
                    """)?.executeAndReturnError(&errorDict)
                continuation.resume(returning: errorDict == nil)
            }
        }
    }

    /// Export the session to Apple Notes if the integration is enabled.
    /// Called at session end; notes may not be generated yet at this point.
    @MainActor
    static func exportIfEnabled(
        settings: AppSettings,
        sessionIndex: SessionIndex,
        utterances: [Utterance],
        notesMarkdown: String? = nil
    ) {
        guard settings.appleNotesEnabled, settings.appleNotesAutoExport else { return }

        let accountName = resolvedAccountName(settings.appleNotesAccountName)
        let folderName = resolvedFolderName(settings.appleNotesFolderName)
        let title = noteTitle(for: sessionIndex)
        let html = buildHTML(
            title: title,
            notesMarkdown: notesMarkdown,
            transcriptEntries: transcriptEntries(from: utterances),
            includeTranscript: settings.appleNotesIncludeTranscript
        )
        Task {
            await runExport(accountName: accountName, folderName: folderName, title: title, html: html)
        }
    }

    /// Sync the current session's notes (and optionally transcript) to Apple Notes.
    /// Called manually from the "Sync to Apple Notes" button in NotesView.
    /// Returns `true` on success, `false` if the AppleScript failed or there is nothing to sync.
    @MainActor
    static func sync(
        settings: AppSettings,
        sessionIndex: SessionIndex,
        records: [SessionRecord],
        notesMarkdown: String?
    ) async -> Bool {
        let hasNotes = notesMarkdown.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let hasTranscript = settings.appleNotesIncludeTranscript && !records.isEmpty
        guard hasNotes || hasTranscript else { return false }

        let accountName = resolvedAccountName(settings.appleNotesAccountName)
        let folderName = resolvedFolderName(settings.appleNotesFolderName)
        let title = noteTitle(for: sessionIndex)
        let html = buildHTML(
            title: title,
            notesMarkdown: notesMarkdown,
            transcriptEntries: transcriptEntries(from: records),
            includeTranscript: settings.appleNotesIncludeTranscript
        )
        let success = await runExport(accountName: accountName, folderName: folderName, title: title, html: html)
        if success { markSynced(sessionID: sessionIndex.id) }
        return success
    }

    // MARK: - Note Title

    static func noteTitle(for sessionIndex: SessionIndex) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: sessionIndex.startedAt)
        let meetingTitle = sessionIndex.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let meetingTitle, !meetingTitle.isEmpty {
            return "[OpenOats] \(dateStr) \(meetingTitle)"
        }
        return "[OpenOats] \(dateStr) Meeting"
    }

    // MARK: - Core Export

    /// Writes HTML to a temp file, runs the AppleScript on the main thread, and
    /// returns `true` on success. NSAppleScript must execute on the main thread —
    /// we use withCheckedContinuation + DispatchQueue.main.async to bridge this
    /// without blocking the caller.
    private static func runExport(accountName: String, folderName: String, title: String, html: String) async -> Bool {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openoats-apple-notes-export.html")

        do {
            try html.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            Log.appleNotes.error("AppleNotes: failed to write temp file: \(error, privacy: .public)")
            return false
        }

        // AppleScript has no backslash escaping inside string literals —
        // replace any double-quotes in user-provided strings with single-quotes.
        let safeAccount = accountName.replacingOccurrences(of: "\"", with: "'")
        let safeFolder  = folderName.replacingOccurrences(of: "\"", with: "'")
        let safeTitle   = title.replacingOccurrences(of: "\"", with: "'")
        let safePath    = tempURL.path  // NSTemporaryDirectory paths are quote-free

        // Read outside the Notes tell block: more reliable, avoids sandbox
        // path-access quirks inside a tell block.
        let source = """
            set noteBody to read POSIX file "\(safePath)" as «class utf8»
            tell application "Notes"
                set targetAccount to account "\(safeAccount)"
                if not (exists folder "\(safeFolder)" of targetAccount) then
                    make new folder at targetAccount with properties {name:"\(safeFolder)"}
                end if
                tell folder "\(safeFolder)" of targetAccount
                    set matchingNotes to every note whose name is "\(safeTitle)"
                    if (count of matchingNotes) > 0 then
                        set body of (first item of matchingNotes) to noteBody
                    else
                        -- No name: Apple Notes derives the note name from the
                        -- body's first line, which is the <h2> title we wrote.
                        -- This avoids a duplicate small-font header above the body.
                        make new note with properties {body:noteBody}
                    end if
                end tell
            end tell
            """

        return await withCheckedContinuation { continuation in
            // NSAppleScript must run on the main thread. Awaiting this continuation
            // yields the main actor, letting DispatchQueue.main pick up the block.
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: tempURL) }
                var errorDict: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&errorDict)
                if let error = errorDict {
                    let code    = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                    Log.appleNotes.error("AppleNotes export failed (code \(code, privacy: .public)): \(message, privacy: .public)")
                    continuation.resume(returning: false)
                } else {
                    Log.appleNotes.info("AppleNotes: exported \"\(safeTitle, privacy: .public)\"")
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func resolvedAccountName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iCloud" : trimmed
    }

    private static func resolvedFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "OpenOats" : trimmed
    }

    // MARK: - HTML Generation

    private struct TranscriptEntry {
        let speaker: String
        let text: String
        let timestamp: Date
    }

    private static func transcriptEntries(from utterances: [Utterance]) -> [TranscriptEntry] {
        utterances.map { TranscriptEntry(speaker: $0.speaker.displayLabel, text: $0.cleanedText ?? $0.text, timestamp: $0.timestamp) }
    }

    private static func transcriptEntries(from records: [SessionRecord]) -> [TranscriptEntry] {
        records.map { TranscriptEntry(speaker: $0.speaker.displayLabel, text: $0.cleanedText ?? $0.text, timestamp: $0.timestamp) }
    }

    private static func buildHTML(
        title: String,
        notesMarkdown: String?,
        transcriptEntries: [TranscriptEntry],
        includeTranscript: Bool
    ) -> String {
        var body = ""
        // Title is the first element so Apple Notes derives the note's `name`
        // from it (same size as the section headers below it).
        // We do NOT set `name` in the AppleScript `make new note` call —
        // that would create a duplicate smaller-font header above the body.
        body += "<h2>\(title)</h2>\n"
        body += "<p><i>(Auto-generated by OpenOats. Manual edits made here will be lost if the note is regenerated in the app.)</i></p>\n"

        if let md = notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
            body += "<h2>Notes</h2>\n"
            // Strip the leading h1 from the notes markdown — the template generates a
            // title heading (e.g. "# Meeting Notes: …") that duplicates the note name.
            body += markdownToHTML(stripLeadingH1(md))
        }

        if includeTranscript, !transcriptEntries.isEmpty {
            body += "<h2>Transcript</h2>\n"
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            for entry in transcriptEntries {
                let ts = timeFormatter.string(from: entry.timestamp)
                body += "<p>[\(ts)] <b>\(entry.speaker):</b> \(entry.text)</p>\n"
            }
        }

        return "<html><head><meta charset=\"UTF-8\"></head><body>\n\(body)</body></html>"
    }

    // MARK: - Sync Tracking

    /// Record that a session was successfully exported. Persists across launches.
    static func markSynced(sessionID: String) {
        var dict = syncRegistry()
        dict[sessionID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: "appleNotesSyncedSessions")
    }

    /// Returns the last sync date for a session, or nil if never synced.
    static func lastSyncDate(for sessionID: String) -> Date? {
        guard let ts = syncRegistry()[sessionID] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private static func syncRegistry() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: "appleNotesSyncedSessions") as? [String: Double] ?? [:]
    }

    // MARK: - Markdown Helpers

    /// Removes the first h1 (`# …`) from a markdown string.
    /// Templates generate a title heading that duplicates the Apple Notes note name.
    static func stripLeadingH1(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[idx].hasPrefix("# ") {
            lines.remove(at: idx)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown → HTML

    static func markdownToHTML(_ markdown: String) -> String {
        var result = ""
        let lines = markdown.components(separatedBy: "\n")
        var inUnorderedList = false
        var inOrderedList = false

        func closeLists() {
            if inUnorderedList { result += "</ul>\n"; inUnorderedList = false }
            if inOrderedList  { result += "</ol>\n"; inOrderedList  = false }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { closeLists(); continue }

            if trimmed.hasPrefix("### ") {
                closeLists(); result += "<h3>\(inlineHTML(String(trimmed.dropFirst(4))))</h3>\n"
            } else if trimmed.hasPrefix("## ") {
                closeLists(); result += "<h2>\(inlineHTML(String(trimmed.dropFirst(3))))</h2>\n"
            } else if trimmed.hasPrefix("# ") {
                closeLists(); result += "<h1>\(inlineHTML(String(trimmed.dropFirst(2))))</h1>\n"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if inOrderedList { result += "</ol>\n"; inOrderedList = false }
                if !inUnorderedList { result += "<ul>\n"; inUnorderedList = true }
                result += "<li>\(inlineHTML(String(trimmed.dropFirst(2))))</li>\n"
            } else if let dotRange = trimmed.range(of: ". "),
                      trimmed[trimmed.startIndex..<dotRange.lowerBound].allSatisfy(\.isNumber) {
                if inUnorderedList { result += "</ul>\n"; inUnorderedList = false }
                if !inOrderedList { result += "<ol>\n"; inOrderedList = true }
                result += "<li>\(inlineHTML(String(trimmed[dotRange.upperBound...])))</li>\n"
            } else {
                closeLists(); result += "<p>\(inlineHTML(trimmed))</p>\n"
            }
        }
        closeLists()
        return result
    }

    private static func inlineHTML(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#,             with: "<b>$1</b>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, with: "<i>$1</i>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_([^_\n]+?)_"#,               with: "<i>$1</i>", options: .regularExpression)
        return s
    }
}
