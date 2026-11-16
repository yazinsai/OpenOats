import Foundation

/// One Transcript line: a speaker's consecutive speech starting at `start` seconds into the Meeting.
public struct Turn: Codable, Sendable, Equatable {
    public var start: TimeInterval
    /// `You`, `Them`, a diarizing backend's label, or nil for an unlabelled mixed import.
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

    static func mixed(_ segments: [TimedSegment], separatesSpeakers: Bool) -> [Turn] {
        join(segments.sorted { $0.start < $1.start }.map { ($0, separatesSpeakers ? $0.speaker : nil) })
    }

    static func isEcho(_ segment: TimedSegment, of system: [TimedSegment]) -> Bool {
        let words = normalizedWords(segment.text)
        guard !words.isEmpty else { return true }
        let heard = Set(system
            .filter { $0.start <= segment.end + echoWindow && $0.end >= segment.start - echoWindow }
            .flatMap { normalizedWords($0.text) })
        let shared = words.filter(heard.contains).count
        return Double(shared) / Double(words.count) >= echoOverlap
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
