import OatsCore
import SwiftUI

/// The rendered Meeting file: Notes as an editorial page, then the Transcript as timed You/Them turns.
/// Frontmatter is dropped; the H1 is dropped when the header already shows it.
struct MeetingFileView: View {
    enum Marker: Hashable { case bullet, number(String), task(Bool) }
    enum Block: Hashable {
        case heading(Int, String), item(Int, Marker, String, [String]), quote(String), code(String), paragraph(String), rule
        case transcript, turn(String, String?, String, continued: Bool)
    }

    let blocks: [Block]

    init(markdown: String, title: String) {
        blocks = Self.parse(markdown).filter { $0 != .heading(1, title) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(block, first: i == 0)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: Block, first: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 2 ? Theme.heading : Theme.uiStrong).foregroundStyle(Theme.ink)
                .padding(.top, first ? 0 : level <= 2 ? Theme.s6 : Theme.s5).padding(.bottom, Theme.s2)
        case let .paragraph(text):
            Text(Self.inline(text)).font(Theme.reading).foregroundStyle(Theme.ink).lineSpacing(5).padding(.vertical, Theme.s2)
        case let .item(depth, marker, text, fields):
            HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                switch marker {
                case .bullet: Text("•").foregroundStyle(Theme.ink3).frame(width: 12)
                case let .number(n): Text(n).monospacedDigit().foregroundStyle(Theme.ink2).frame(minWidth: 12, alignment: .trailing)
                case let .task(done):
                    Image(systemName: done ? "checkmark.square.fill" : "square").font(Theme.ui)
                        .foregroundStyle(done ? Theme.accent : Theme.ink3).frame(width: 12)
                        .accessibilityLabel(done ? "Done" : "To do")
                }
                VStack(alignment: .leading, spacing: Theme.s1 + 2) {
                    Text(Self.inline(text)).foregroundStyle(Theme.ink).lineSpacing(5)
                    if !fields.isEmpty {
                        HStack(spacing: Theme.s1 + 2) {
                            ForEach(fields, id: \.self) { field in
                                Text(field).font(Theme.caption).foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, 6).padding(.vertical, 2).card(Theme.ink2, radius: Theme.r1, fill: 0.06)
                            }
                        }
                    }
                }
            }
            .font(Theme.reading)
            .padding(.leading, CGFloat(depth) * Theme.s5).padding(.vertical, Theme.s1 + 1)
        case let .quote(text):
            Text(Self.inline(text)).font(Theme.reading).italic().foregroundStyle(Theme.ink2).lineSpacing(5)
                .padding(.leading, Theme.s4).overlay(alignment: .leading) { Capsule().fill(Theme.accent.opacity(0.4)).frame(width: 3) }
                .padding(.vertical, Theme.s2)
        case let .code(text):
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink).lineSpacing(3)
                .padding(Theme.s3).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.r2, style: .continuous).fill(Theme.raised))
                .padding(.vertical, Theme.s2)
        case .rule:
            Theme.line.frame(height: 1).padding(.vertical, Theme.s4)
        case .transcript:
            VStack(alignment: .leading, spacing: Theme.s3) {
                if !first { Theme.line.frame(height: 1).padding(.bottom, Theme.s5) }
                HStack(alignment: .firstTextBaseline) {
                    Text("Transcript").font(Theme.heading).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    ForEach([("You", Theme.accent), ("Them", Theme.them)], id: \.0) { name, color in
                        Label { Text(name) } icon: { Circle().fill(color).frame(width: 6, height: 6) }
                            .font(Theme.meta).foregroundStyle(Theme.ink2)
                    }
                }
            }
            .padding(.top, first ? 0 : Theme.s6).padding(.bottom, Theme.s1)
        case let .turn(time, speaker, text, continued):
            HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
                Text(Self.shortTime(time)).font(Theme.mono).monospacedDigit().foregroundStyle(Theme.ink3)
                    .frame(width: 52, alignment: .leading)
                    .accessibilityLabel("At \(time)")
                VStack(alignment: .leading, spacing: Theme.s1) {
                    if let speaker, !continued {
                        Text(speaker).font(Theme.eyebrow).textCase(.uppercase).tracking(0.6).foregroundStyle(Self.color(speaker))
                    }
                    Text(Self.inline(text)).font(Theme.reading).foregroundStyle(Theme.ink).lineSpacing(5)
                }
            }
            .padding(.top, continued ? Theme.s2 : Theme.s5)
            .accessibilityElement(children: .contain)
        }
    }

    static func color(_ speaker: String) -> Color {
        speaker == "You" ? Theme.accent : speaker == "Them" ? Theme.them : Theme.ink2
    }

    /// `00:05:23` → `05:23`; hours stay when there are any.
    static func shortTime(_ time: String) -> String { time.hasPrefix("00:") ? String(time.dropFirst(3)) : time }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var inTranscript = false
        var lastSpeaker: String?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for line in Frontmatter.body(markdown).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if inTranscript, let m = trimmed.wholeMatch(of: /\[(\d{2}:\d{2}:\d{2})\](?: \*\*(.+?):\*\*)? ?(.*)/) {
                flush()
                let speaker = m.2.map(String.init)
                blocks.append(.turn(String(m.1), speaker, String(m.3), continued: speaker != nil && speaker == lastSpeaker))
                lastSpeaker = speaker
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes != trimmed.startIndex, trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes), text = String(trimmed[hashes...].dropFirst())
                inTranscript = level == 2 && text == "Transcript"
                lastSpeaker = nil
                blocks.append(inTranscript ? .transcript : .heading(level, text))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if let m = trimmed.wholeMatch(of: /(?:[-*+]|(\d+\.)) (?:\[([ xX])\] )?(.*)/) {
                flush()
                let depth = (line.count - line.drop { $0 == " " || $0 == "\t" }.count) / 2
                let marker: Marker = m.2.map { .task($0 != " ") } ?? m.1.map { .number(String($0)) } ?? .bullet
                // Dataview fields (`[owner:: You]`) become chips.
                var text = String(m.3), fields: [String] = []
                for f in text.matches(of: /\s*\[(\w+):: ([^\]]+)\]/).reversed() {
                    let date = (try? Date(String(f.2), strategy: .iso8601.year().month().day())).map { $0.formatted(.dateTime.day().month()) }
                    fields.insert(f.1 == "owner" ? String(f.2) : "\(f.1.capitalized) \(date ?? String(f.2))", at: 0)
                    text.removeSubrange(f.range)
                }
                blocks.append(.item(depth, marker, text, fields))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}
