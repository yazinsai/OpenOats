import Foundation

public enum NotesError: LocalizedError {
    case empty
    public var errorDescription: String? {
        "The model returned empty notes. Thinking mode may be enabled on the server, or the token budget ran out before the notes were written."
    }
}

/// The Notes step: Vocabulary correction, then Notes from the notes prompt, in pieces when the Transcript exceeds the model's context.
public enum NotesWriter {
    public static let defaultPrompt = """
    You write meeting notes in Markdown from a meeting transcript. "You" is the person who recorded the meeting; "Them" is everyone else.
    Write in the language of the transcript, using these sections in this order:

    ## Summary
    One to three short paragraphs, past tense, no bullet points: what was discussed and decided.

    ## Decisions
    A flat bullet list of decisions made.

    ## Action Items
    One line per task: `- [ ] task [owner:: You]` (owner only if known, You or Them; add `[due:: YYYY-MM-DD]` only if a date was set).

    ## Open Questions
    A bullet list of unresolved questions that need follow-up.

    Leave out any section that would be empty. Don't invent facts.
    """

    /// Tokens kept free for the model's reply.
    static let replyTokens = 2_048

    public static func step(prompt: String = defaultPrompt, vocabulary: [String] = []) -> NotesStep {
        { turns, backend in
            let corrected = try await correctVocabulary(turns, vocabulary, backend)
            var system = prompt + "\n\nStart your reply with one line `Title: <short meeting title>`, then the notes."
            if !vocabulary.isEmpty { system += " Spell these names and terms exactly: \(vocabulary.joined(separator: ", "))." }
            var notes = Notes(reply: try await write(corrected.plainText, transcript: true, system: system, backend))
            notes.markdown = omitEmptySections(notes.markdown)
            if notes.title == nil, notes.markdown.hasPrefix("# ") { // a model that headed its notes with the title
                let lines = notes.markdown.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                notes.title = String(lines[0].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                notes.markdown = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            guard !notes.markdown.isEmpty else { throw NotesError.empty }
            notes.turns = corrected == turns ? nil : corrected
            return notes
        }
    }

    /// Asks only for misheard-term replacements and applies them in code, so the Transcript otherwise stays verbatim.
    static func correctVocabulary(_ turns: [Turn], _ vocabulary: [String], _ backend: any NotesBackend) async throws -> [Turn] {
        guard !vocabulary.isEmpty, !turns.isEmpty else { return turns }
        let system = """
        You fix speech-recognition mistakes in names and terms. The Vocabulary is: \(vocabulary.joined(separator: ", ")).
        Find places in the transcript where a Vocabulary term was written wrongly (misspelled, split into other words, or merged). \
        Reply with only a JSON array like [{"from": "exact wrong text as it appears", "to": "Vocabulary term"}], or [] if there are none. \
        Never suggest any other change.
        """
        var replacements: [String: String] = [:]
        for piece in chunks(turns.plainText, maxChars: budget(system, backend)) {
            let reply = try await backend.complete(system: system, user: piece)
            guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close,
                  let pairs = try? JSONDecoder().decode([[String: String]].self, from: Data(reply[open...close].utf8)) else { continue }
            for pair in pairs {
                guard let from = pair["from"]?.trimmingCharacters(in: .whitespaces), !from.isEmpty,
                      let term = vocabulary.first(where: { $0.caseInsensitiveCompare(pair["to"] ?? "") == .orderedSame }),
                      from != term, soundsAlike(from, term) else { continue }
                replacements[from] = term
            }
        }
        guard !replacements.isEmpty else { return turns }
        return turns.map { turn in
            var turn = turn
            for (from, to) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
                turn.text = turn.text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: to),
                                                           options: [.regularExpression, .caseInsensitive])
            }
            return turn
        }
    }

    /// A replacement must spell roughly the same letters as the term, so it can't swallow neighbouring words.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter(\.isLetter)), y = Array(b.lowercased().filter(\.isLetter))
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var prev = row[0]; row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1)); prev = cur
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count, 1)) >= 0.6
    }

    /// Summarises `text` in one call if it fits, else part by part and then combines the partial notes.
    static func write(_ text: String, transcript: Bool, system: String, _ backend: any NotesBackend, depth: Int = 0) async throws -> String {
        let what = transcript ? "the meeting transcript" : "notes from consecutive parts of one meeting"
        let pieces = depth < 3 ? chunks(text, maxChars: budget(system, backend)) : [text]
        guard pieces.count > 1 else {
            let ask = transcript ? "Write the meeting notes:" : "Combine them into one set of meeting notes, merging duplicates:"
            return try await backend.complete(system: system, user: "Here is \(what):\n\n\(text)\n\n\(ask)")
        }
        var parts: [String] = []
        for (i, piece) in pieces.enumerated() {
            let user = "Here is part \(i + 1) of \(pieces.count) of \(what):\n\n\(piece)\n\nWrite the meeting notes for this part:"
            parts.append(try await backend.complete(system: system, user: user))
        }
        return try await write(parts.joined(separator: "\n\n---\n\n"), transcript: false, system: system, backend, depth: depth + 1)
    }

    /// Characters of input per call, at ~4 characters per token.
    static func budget(_ system: String, _ backend: any NotesBackend) -> Int {
        max(1_000, backend.contextTokens - replyTokens - system.count / 4 - 100) * 4
    }

    /// Splits text at line breaks into pieces of at most `maxChars` (hard-splitting overlong lines).
    static func chunks(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = [], current = ""
        for line in text.components(separatedBy: "\n") {
            var line = Substring(line)
            while line.count > maxChars {
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(String(line.prefix(maxChars)))
                line = line.dropFirst(maxChars)
            }
            if !current.isEmpty, current.count + line.count + 1 > maxChars { pieces.append(current); current = "" }
            current += current.isEmpty ? line : "\n" + line
        }
        return current.isEmpty ? pieces : pieces + [current]
    }

    /// Drops `##` sections with no content, or only "None" / "N/A".
    static func omitEmptySections(_ markdown: String) -> String {
        let sections = ("\n" + markdown).components(separatedBy: "\n## ")
        let kept = sections.prefix(1) + sections.dropFirst().filter { section in
            let body = section.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let bare = body.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-*•. \n\t"))
            return !["", "none", "n/a", "na", "nothing"].contains(bare)
        }
        return kept.joined(separator: "\n## ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
