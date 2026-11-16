import Darwin
import Foundation
import OatsCore
import OatsOnDevice
import Testing

/// Opt-in golden tests on a real meeting clip (never committed): `OATS_GOLDEN_CLIP`, default /tmp/oatbench/clip.wav,
/// with the 1.x live transcript `live.txt` next to it. Skipped when the clip is absent.
let clip = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATS_GOLDEN_CLIP"] ?? "/tmp/oatbench/clip.wav")
let live = clip.deletingLastPathComponent().appendingPathComponent("live.txt")
let hasClip = FileManager.default.fileExists(atPath: clip.path)

@Suite(.serialized, .enabled(if: hasClip))
struct GoldenTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oats-golden-\(UUID().uuidString)")
    var store: MeetingStore { MeetingStore(root: root.appendingPathComponent("Meetings")) }

    /// "No dropped speech": ≥ 90 % of live.txt lines (with ≥ 3 content words) have at least half their content words in
    /// our lines within ±20 s, and ≥ 85 % of all live content words (with repeats) appear in ours. (live.txt mishears
    /// too: Gemini 3 Flash on the same clip scores 87/94 lines and 83.5 %.)
    /// "No mid-sentence splits": ≥ 90 % of Transcript lines end in terminal punctuation, and more than in live.txt.
    /// Processing ≤ 3 min per hour of audio.
    @Test func mixedClipBeatsLiveTranscript() async throws {
        let folder = try store.importAudio([clip], language: "en")
        let baseline = residentMB()
        let started = Date()
        let status = try await Processing.run(folder, options: options())
        let seconds = Date().timeIntervalSince(started)
        let audio = try #require(status.duration)
        let lines = try transcriptLines(status)
        let ours = lines.map(\.text)
        let liveTimed = try liveLines()
        let theirs = liveTimed.map(\.text)
        let coverage = Self.coverage(of: theirs, in: ours)
        let kept = Self.keptLines(liveTimed, in: lines)
        print("""
        golden mixed: \(lines.count) lines, \(Self.words(ours).count) words (live \(theirs.count) lines, \(Self.words(theirs).count) words); \
        live lines kept \(kept.kept)/\(kept.total), content-word coverage \(pct(coverage)); terminal punctuation \(pct(Self.terminal(ours))) (live \(pct(Self.terminal(theirs)))); \
        Processing \(String(format: "%.1f", seconds)) s for \(String(format: "%.0f", audio)) s audio \
        (\(String(format: "%.1f", seconds / audio * 60)) min/hour); RSS \(baseline) MB before, \(residentMB()) MB after unload
        """)
        #expect(status.state == .done)
        #expect(Double(kept.kept) >= Double(kept.total) * 0.9)
        #expect(coverage >= 0.85)
        #expect(Self.terminal(ours) >= 0.9 && Self.terminal(ours) > Self.terminal(theirs))
        #expect(seconds <= audio / 20)
    }

    /// Speakers, not headphones: the Mic track hears Them. System = clip; Mic = the clip 150 ms later at -12 dB plus noise.
    /// Almost nothing may come out as You, and Them must still cover the live transcript.
    @Test func echoOfThemOnMicTrackIsDropped() async throws {
        let system = try TrackAudio.samples(of: clip)
        let delay = 2400
        var seed: UInt32 = 1 // fixed noise so the result is repeatable
        let mic = (0..<system.count).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (i >= delay ? system[i - delay] * 0.25 : 0) + (Float(seed) / Float(UInt32.max) - 0.5) * 0.006
        }
        let folder = try store.create(language: "en")
        try Self.pcm(system).write(to: folder.systemTrackURL)
        try Self.pcm(mic).write(to: folder.micTrackURL)
        try folder.updateStatus { $0.state = .processing }
        let status = try await Processing.run(folder, options: options())
        let lines = try transcriptLines(status)
        let you = Self.words(lines.filter { $0.speaker == "You" }.map(\.text)).count
        let them = Self.words(lines.filter { $0.speaker == "Them" }.map(\.text)).count
        let coverage = Self.coverage(of: try liveLines().map(\.text), in: lines.map(\.text))
        print("golden echo: You \(you) words, Them \(them) words (echo leak \(pct(Double(you) / Double(max(them, 1))))); "
            + "live coverage \(pct(coverage))")
        #expect(status.state == .done)
        #expect(Double(you) <= Double(them) * 0.02)
        #expect(coverage >= 0.85)
    }

    func options() -> ProcessingOptions {
        ProcessingOptions(transcription: OnDeviceTranscription(language: "en"), notesFolder: root.appendingPathComponent("Notes"),
                          keepAudio: false)
    }

    /// Each `[MM:SS] you: text` line of live.txt.
    func liveLines() throws -> [(time: Int, text: String)] {
        try String(contentsOf: live, encoding: .utf8).split(separator: "\n").map { line in
            let parts = line.dropFirst().split(separator: ":", maxSplits: 2)
            return (Int(parts[0])! * 60 + Int(parts[1].prefix(2))!, String(parts[2]))
        }
    }

    /// Every `[HH:MM:SS] **X:** text` line of the Meeting file.
    func transcriptLines(_ status: MeetingStatus) throws -> [(time: Int, speaker: String, text: String)] {
        let file = try String(contentsOfFile: try #require(status.meetingFile), encoding: .utf8)
        return file.components(separatedBy: "## Transcript")[1].split(separator: "\n").compactMap { line in
            guard let open = line.range(of: "**"), let close = line.range(of: ":** ") else { return nil }
            let t = line.dropFirst().prefix(8).split(separator: ":").compactMap { Int($0) }
            return (t[0] * 3600 + t[1] * 60 + t[2], String(line[open.upperBound..<close.lowerBound]), String(line[close.upperBound...]))
        }
    }

    /// Live lines with ≥ 3 content words of which at least half occur in `lines` within ±20 s.
    static func keptLines(_ live: [(time: Int, text: String)], in lines: [(time: Int, speaker: String, text: String)])
        -> (kept: Int, total: Int) {
        let checked = live.filter { contentWords($0.text).count >= 3 }
        let kept = checked.filter { line in
            let near = Set(lines.filter { abs($0.time - line.time) <= 20 }.flatMap { contentWords($0.text) })
            let words = contentWords(line.text)
            return words.filter(near.contains).count * 2 >= words.count
        }
        return (kept.count, checked.count)
    }

    static let stopwords: Set<String> = [
        "the", "and", "you", "that", "this", "for", "but", "not", "are", "was", "have", "with", "its", "it's", "just",
        "like", "yeah", "uh", "um", "so", "it", "is", "to", "a", "i", "of", "in", "on", "do", "be", "we", "me", "my",
    ]

    static func words(_ lines: [String]) -> [String] {
        lines.flatMap { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) }.filter { !$0.isEmpty }
    }

    static func contentWords(_ text: String) -> [String] {
        words([text]).filter { $0.count > 2 && !stopwords.contains($0) }
    }

    /// Share of `reference` content words (with repeats) that also occur in `lines`.
    static func coverage(of reference: [String], in lines: [String]) -> Double {
        func counts(_ l: [String]) -> [String: Int] {
            l.flatMap(contentWords).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let want = counts(reference), have = counts(lines)
        let found = want.reduce(0) { $0 + min($1.value, have[$1.key] ?? 0) }
        return Double(found) / Double(max(1, want.values.reduce(0, +)))
    }

    static func terminal(_ lines: [String]) -> Double {
        let ended = lines.filter { $0.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false }
        return Double(ended.count) / Double(max(1, lines.count))
    }

    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }
}

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

func residentMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return Int(info.resident_size) / 1_048_576
}
