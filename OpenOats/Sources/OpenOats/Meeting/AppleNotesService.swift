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
        guard settings.appleNotesEnabled, settings.appleNotesAutoExport, settings.appleNotesIncludeTranscript else { return }

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
            let existingNoteID = storedNoteID(for: sessionIndex.id)
            if let noteID = await runExport(accountName: accountName, folderName: folderName, title: title, html: html, existingNoteID: existingNoteID) {
                markSynced(sessionID: sessionIndex.id, noteID: noteID)
            }
        }
    }

    /// Sync the current session's notes (and optionally transcript) to Apple Notes.
    /// Called manually from the "Export" button in NotesView.
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
        let existingNoteID = storedNoteID(for: sessionIndex.id)
        guard let noteID = await runExport(accountName: accountName, folderName: folderName, title: title, html: html, existingNoteID: existingNoteID) else { return false }
        markSynced(sessionID: sessionIndex.id, noteID: noteID)
        return true
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
    /// Returns the note's persistent ID on success, nil on failure.
    /// Callers should store the returned ID and pass it back on subsequent exports
    /// so the same note is updated rather than a new one created.
    private static func runExport(accountName: String, folderName: String, title: String, html: String, existingNoteID: String?) async -> String? {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openoats-apple-notes-export.html")

        do {
            try html.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            Log.appleNotes.error("AppleNotes: failed to write temp file: \(error, privacy: .public)")
            return nil
        }

        // AppleScript has no backslash escaping inside string literals —
        // replace any double-quotes in user-provided strings with single-quotes.
        let safeAccount  = accountName.replacingOccurrences(of: "\"", with: "'")
        let safeFolder   = folderName.replacingOccurrences(of: "\"", with: "'")
        let safeTitle    = title.replacingOccurrences(of: "\"", with: "'")
        let safePath     = tempURL.path  // NSTemporaryDirectory paths are quote-free
        let safeNoteID   = existingNoteID ?? ""

        // Strategy:
        // 1. If we have a stored note ID, update by ID (most reliable — immune to renames).
        // 2. Fall back to name search to recover from missing IDs (e.g. first export).
        // 3. If nothing matches, create a new note and return its ID for future use.
        // The script returns the note ID as its last value so Swift can store it.
        let source = """
            set noteBody to read POSIX file "\(safePath)" as «class utf8»
            tell application "Notes"
                set targetAccount to account "\(safeAccount)"
                if not (exists folder "\(safeFolder)" of targetAccount) then
                    make new folder at targetAccount with properties {name:"\(safeFolder)"}
                end if
                set targetFolder to folder "\(safeFolder)" of targetAccount
                -- 1. Try stored ID first
                if "\(safeNoteID)" is not "" then
                    try
                        set targetNote to note id "\(safeNoteID)"
                        set body of targetNote to noteBody
                        return id of targetNote
                    end try
                end if
                -- 2. Fall back to name search
                set matchingNotes to every note of targetFolder whose name is "\(safeTitle)"
                if (count of matchingNotes) > 0 then
                    set targetNote to first item of matchingNotes
                    set body of targetNote to noteBody
                    return id of targetNote
                end if
                -- 3. Create new note; Apple Notes derives its name from the first <h2>
                set newNote to make new note at targetFolder with properties {body:noteBody}
                return id of newNote
            end tell
            """

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: tempURL) }
                var errorDict: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&errorDict)
                if let error = errorDict {
                    let code    = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
                    Log.appleNotes.error("AppleNotes export failed (code \(code, privacy: .public)): \(message, privacy: .public)")
                    continuation.resume(returning: nil)
                } else {
                    let noteID = result?.stringValue
                    Log.appleNotes.info("AppleNotes: exported \"\(safeTitle, privacy: .public)\" id=\(noteID ?? "unknown", privacy: .public)")
                    continuation.resume(returning: noteID)
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
    static func markSynced(sessionID: String, noteID: String? = nil) {
        var dates = syncRegistry()
        dates[sessionID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: "appleNotesSyncedSessions")

        if let noteID {
            var ids = noteIDRegistry()
            ids[sessionID] = noteID
            UserDefaults.standard.set(ids, forKey: "appleNotesNoteIDs")
        }
    }

    /// Returns the last sync date for a session, or nil if never synced.
    static func lastSyncDate(for sessionID: String) -> Date? {
        guard let ts = syncRegistry()[sessionID] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Returns the Apple Notes note ID stored for a session, or nil if never exported.
    static func storedNoteID(for sessionID: String) -> String? {
        noteIDRegistry()[sessionID]
    }

    private static func syncRegistry() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: "appleNotesSyncedSessions") as? [String: Double] ?? [:]
    }

    private static func noteIDRegistry() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "appleNotesNoteIDs") as? [String: String] ?? [:]
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
