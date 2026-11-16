import Foundation

/// One Transcript line: a speaker's consecutive speech starting at `start` seconds into the Meeting.
public struct Turn: Codable, Sendable, Equatable {
    public var start: TimeInterval
    /// `You`, `Them`, a diarizing backend's label, or `Speaker` for an unlabelled mixed import.
    public var speaker: String?
    public var text: String

    public init(start: TimeInterval, speaker: String?, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// Step 2: merge per-track segments by time into turns and drop Mic-track echoes of Them.
enum TranscriptMerge {
    /// Same-speaker segments closer than this are joined into one turn.
    static let joinGap: TimeInterval = 2
    /// How far around a mic segment to look for the System-track speech it might echo.
    static let echoWindow: TimeInterval = 1.5
    /// Share of a mic segment's words found in overlapping Them speech above which it is echo.
    static let echoOverlap = 0.6

    static func merge(mic: [TimedSegment], system: [TimedSegment]) -> [Turn] {
        let you = mic.filter { !isEcho($0, of: system) }.map { ($0, "You") }
        let them = system.map { ($0, "Them") }
        return join((you + them).sorted { $0.0.start < $1.0.start })
    }

    /// Without speaker labels, consecutive segments may be different people, so each stays its own line.
    static func mixed(_ segments: [TimedSegment], separatesSpeakers: Bool) -> [Turn] {
        let sorted = segments.sorted { $0.start < $1.start }
        guard separatesSpeakers else {
            return sorted.compactMap {
                let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Turn(start: $0.start, speaker: "Speaker", text: text)
            }
        }
        return join(sorted.map { ($0, $0.speaker ?? "Speaker") })
    }

    static func isEcho(_ segment: TimedSegment, of system: [TimedSegment]) -> Bool {
        let words = normalizedWords(segment.text)
        guard !words.isEmpty else { return true }
        let heard = Set(system
            .filter { $0.start <= segment.end + echoWindow && $0.end >= segment.start - echoWindow }
            .flatMap { normalizedWords($0.text) })
        // The Mic track hears Them quieter, so its words are often slightly off ("pig" for "pic").
        let shared = words.filter { word in
            heard.contains(word) || word.count >= 3 && heard.contains { editDistance(word, $0) <= max(1, word.count / 4) }
        }.count
        return Double(shared) / Double(words.count) >= echoOverlap
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in a.indices {
            var previous = row[0]
            row[0] = i + 1
            for j in b.indices {
                (previous, row[j + 1]) = (row[j + 1], min(row[j + 1] + 1, row[j] + 1, previous + (a[i] == b[j] ? 0 : 1)))
            }
        }
        return row[b.count]
    }

    private static func join(_ items: [(TimedSegment, String?)]) -> [Turn] {
        var turns: [Turn] = []
        var lastEnd = -TimeInterval.infinity
        for (segment, speaker) in items {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.speaker == speaker, segment.start - lastEnd <= joinGap {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(start: segment.start, speaker: speaker, text: text))
            }
            lastEnd = max(segment.end, segment.start)
        }
        return turns
    }

    /// Lowercased alphanumeric words (from 1.x `TextSimilarity`).
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
