import SwiftUI

/// Compact vertical bar displayed during active meetings.
/// Shows a waveform visualization and suggestion bubbles that float out.
/// Reads display state from `MiniBarState` so the view hierarchy is never
/// recreated — only the observable properties are mutated.
struct MiniBarContent: View {
    let state: MiniBarState

    var body: some View {
        // Tiny pill: mini waveform + status dot
        HStack(spacing: 3) {
            MiniWaveformView(level: state.audioLevel)
                .frame(width: 22, height: 10)

            Circle()
                .fill(state.isGenerating ? Color.orange : Color.green)
                .frame(width: 5, height: 5)
                .scaleEffect(1.0 + CGFloat(state.audioLevel) * 0.3)
                .animation(.easeOut(duration: 0.1), value: state.audioLevel)
        }
        .frame(width: 40, height: 18)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            state.onTap()
        }
    }
}

// MARK: - Waveform Visualization

/// Tiny horizontal waveform for the mini pill.
private struct MiniWaveformView: View {
    let level: Float

    private let barCount = 5

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                WaveformBar(
                    level: level,
                    barIndex: i,
                    totalBars: barCount
                )
            }
        }
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
            .frame(width: 2, height: nil)
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
