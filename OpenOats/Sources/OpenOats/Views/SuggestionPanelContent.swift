import SwiftUI

/// Content view for the floating suggestion side panel.
/// Shows the current suggestion (raw or streaming) with fading previous suggestions.
struct SuggestionPanelContent: View {
    let engine: SuggestionEngine?

    private var suggestions: [RealtimeSuggestion] {
        engine?.activeSuggestions ?? []
    }

    private var isStreaming: Bool {
        engine?.isStreaming ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(isStreaming ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text("OpenOats")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if suggestions.isEmpty {
                idleView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            SuggestionPanelCard(
                                suggestion: suggestion,
                                isPrimary: index == 0,
                                fadeFraction: fadeFraction(for: index)
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var idleView: some View {
        VStack(spacing: 6) {
            Text("Processing...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opacity fraction for suggestion at the given index.
    /// Index 0 = 1.0, index 1 = 0.6, index 2 = 0.3
    private func fadeFraction(for index: Int) -> Double {
        switch index {
        case 0: 1.0
        case 1: 0.6
        default: 0.3
        }
    }
}

// MARK: - Card

private struct SuggestionPanelCard: View {
    let suggestion: RealtimeSuggestion
    let isPrimary: Bool
    let fadeFraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Source breadcrumb
            if !suggestion.sourceBreadcrumb.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 8))
                    Text(suggestion.sourceBreadcrumb)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }

            // Main text (raw snippet or streamed synthesis)
            if let md = try? AttributedString(markdown: suggestion.displayText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(md)
                    .font(.system(size: isPrimary ? 12 : 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(suggestion.displayText)
                    .font(.system(size: isPrimary ? 12 : 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            // Streaming indicator
            if suggestion.lifecycle == .streaming {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Synthesizing...")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            // Score badge (subtle)
            if isPrimary, let topPack = suggestion.contextPacks.first {
                Text(String(format: "%.0f%% match", topPack.score * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPrimary ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(fadeFraction)
        .animation(.easeOut(duration: 0.3), value: fadeFraction)
    }
}
