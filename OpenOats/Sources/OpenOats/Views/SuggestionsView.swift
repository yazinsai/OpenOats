import SwiftUI

struct SuggestionsView: View {
    let suggestions: [Suggestion]
    let isGenerating: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Generating indicator (no partial text shown)
                if isGenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(String(localized: "evaluating"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentTeal.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Suggestions — most recent first, top card emphasized
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionCard(suggestion: suggestion, isPrimary: index == 0)
                }

                if suggestions.isEmpty && !isGenerating {
                    VStack(spacing: 8) {
                        Text(String(localized: "no_suggestions_yet"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "suggestions_appear_when_the_conversation_reaches_a"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Bullet Parsing

/// A parsed bullet from LLM output: headline + optional detail.
struct ParsedBullet: Identifiable {
    let id = UUID()
    let headline: String
    let detail: String?
}

/// Parses LLM output in `• Headline\n> Detail` format into structured bullets.
private func parseBullets(_ text: String) -> [ParsedBullet] {
    let lines = text.components(separatedBy: "\n")
    var bullets: [ParsedBullet] = []
    var currentHeadline: String?
    var currentDetail: String?

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
            // Save previous bullet
            if let headline = currentHeadline {
                bullets.append(ParsedBullet(headline: headline, detail: currentDetail))
            }
            let stripped = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            currentHeadline = stripped.isEmpty ? nil : stripped
            currentDetail = nil
        } else if trimmed.hasPrefix(">") {
            let detail = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !detail.isEmpty {
                if currentDetail != nil {
                    currentDetail! += " " + detail
                } else {
                    currentDetail = detail
                }
            }
        } else if !trimmed.isEmpty && trimmed != "—" {
            if currentHeadline != nil {
                if currentDetail != nil {
                    currentDetail! += " " + trimmed
                } else {
                    currentDetail = trimmed
                }
            }
        }
    }

    if let headline = currentHeadline {
        bullets.append(ParsedBullet(headline: headline, detail: currentDetail))
    }

    return bullets
}

// MARK: - Bullet Row

private struct BulletRow: View {
    let bullet: ParsedBullet
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if bullet.detail != nil {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: 16)
                }

                Text(bullet.headline)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(bullet.detail != nil && isHovering ? Color.primary.opacity(0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onHover { hovering in isHovering = hovering }
            .onTapGesture {
                if bullet.detail != nil {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            }

            if let detail = bullet.detail, isExpanded {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Suggestion Card

private struct SuggestionCard: View {
    let suggestion: Suggestion
    var isPrimary: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let bullets = parseBullets(suggestion.text)

            if bullets.isEmpty {
                Text(suggestion.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                ForEach(bullets) { bullet in
                    BulletRow(bullet: bullet)
                }
            }

            // Source labels with header context
            if !suggestion.kbHits.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                    let sourceLabels = suggestion.kbHits.prefix(3).map { hit in
                        hit.headerContext.isEmpty ? hit.sourceFile : "\(hit.sourceFile) > \(hit.headerContext)"
                    }
                    Text(sourceLabels.joined(separator: " | "))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPrimary ? Color.accentTeal.opacity(0.06) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
