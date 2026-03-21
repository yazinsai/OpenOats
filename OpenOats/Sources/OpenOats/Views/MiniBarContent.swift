import SwiftUI

/// Compact vertical bar displayed during active meetings.
/// Shows a waveform visualization and suggestion bubbles that float out.
struct MiniBarContent: View {
    let audioLevel: Float
    let suggestions: [Suggestion]
    let isGenerating: Bool
    let onTap: () -> Void

    @State private var visibleSuggestionID: UUID?
    @State private var bubbleOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            // Main vertical bar
            VStack(spacing: 0) {
                // Waveform section
                WaveformView(level: audioLevel)
                    .frame(width: 56, height: 120)

                Divider()
                    .frame(width: 32)
                    .padding(.vertical, 4)

                // Status indicator
                Circle()
                    .fill(isGenerating ? Color.orange : Color.green)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.4)
                    .animation(.easeOut(duration: 0.1), value: audioLevel)

                Spacer()

                // Suggestion count badge
                if !suggestions.isEmpty {
                    Text("\(suggestions.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .padding(.bottom, 8)
                        .onTapGesture {
                            showNextSuggestion()
                        }
                }
            }
            .frame(width: 56, height: 200)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                onTap()
            }

            // Floating suggestion bubble
            if let suggestion = currentSuggestion {
                SuggestionBubble(text: suggestion.text)
                    .offset(x: 8 + bubbleOffset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            bubbleOffset = 0
                        }
                        // Auto-dismiss after 6 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                visibleSuggestionID = nil
                            }
                        }
                    }
            }
        }
        .frame(width: 300, height: 200, alignment: .leading)
        .onChange(of: suggestions.count) {
            if let latest = suggestions.first, visibleSuggestionID != latest.id {
                showSuggestion(latest)
            }
        }
    }

    private var currentSuggestion: Suggestion? {
        guard let id = visibleSuggestionID else { return nil }
        return suggestions.first { $0.id == id }
    }

    private func showSuggestion(_ suggestion: Suggestion) {
        bubbleOffset = -20
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            visibleSuggestionID = suggestion.id
        }
    }

    private func showNextSuggestion() {
        guard !suggestions.isEmpty else { return }
        if let currentID = visibleSuggestionID,
           let idx = suggestions.firstIndex(where: { $0.id == currentID }),
           idx + 1 < suggestions.count {
            showSuggestion(suggestions[idx + 1])
        } else {
            showSuggestion(suggestions[0])
        }
    }
}

// MARK: - Waveform Visualization

/// Vertical waveform that reacts to audio level.
private struct WaveformView: View {
    let level: Float

    private let barCount = 7

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                WaveformBar(
                    level: level,
                    barIndex: i,
                    totalBars: barCount
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Individual waveform bar with height driven by audio level.
private struct WaveformBar: View {
    let level: Float
    let barIndex: Int
    let totalBars: Int

    // Each bar has a slightly different response curve for organic feel
    private var heightFraction: CGFloat {
        let center = CGFloat(totalBars) / 2.0
        let distance = abs(CGFloat(barIndex) - center) / center
        // Center bars are taller, edge bars shorter
        let baseHeight: CGFloat = 0.15
        let sensitivity = 1.0 - distance * 0.5
        // Phase offset per bar for wave-like motion
        let phase = sin(Double(barIndex) * 0.8 + Double(level) * 12.0) * 0.15
        let computed = baseHeight + CGFloat(level) * sensitivity + CGFloat(phase) * CGFloat(level)
        return min(max(computed, baseHeight), 1.0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(width: 4, height: nil)
            .frame(maxHeight: .infinity)
            .scaleEffect(y: heightFraction, anchor: .center)
            .animation(.easeOut(duration: 0.08), value: level)
    }

    private var barColor: Color {
        if level > 0.05 {
            return Color.green.opacity(0.6 + Double(level) * 0.4)
        }
        return Color.primary.opacity(0.12)
    }
}

// MARK: - Suggestion Bubble

/// A floating bubble that appears beside the mini bar showing a suggestion.
private struct SuggestionBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Arrow pointing left toward the bar
            Triangle()
                .fill(.ultraThinMaterial)
                .frame(width: 8, height: 14)
                .rotationEffect(.degrees(-90))
                .offset(x: 2)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .frame(maxWidth: 200, alignment: .leading)
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Simple triangle shape for the bubble arrow.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
