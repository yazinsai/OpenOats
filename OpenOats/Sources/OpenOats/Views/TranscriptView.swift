import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(utterances) { utterance in
                        UtteranceBubble(utterance: utterance)
                            .id(utterance.id)
                    }

                    // Volatile text
                    if !volatileYouText.isEmpty {
                        VolatileIndicator(text: volatileYouText, speaker: .you)
                            .id("volatile-you")
                    }

                    if !volatileThemText.isEmpty {
                        VolatileIndicator(text: volatileThemText, speaker: .them)
                            .id("volatile-them")
                    }
                }
                .padding(16)
            }
            .onChange(of: utterances.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = utterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                proxy.scrollTo("volatile-you", anchor: .bottom)
            }
            .onChange(of: volatileThemText) {
                proxy.scrollTo("volatile-them", anchor: .bottom)
            }
        }
    }
}

private struct UtteranceBubble: View {
    let utterance: Utterance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(utterance.speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(utterance.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            Text(utterance.displayText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(speaker.color)
                    .frame(width: 4, height: 4)
                    .opacity(0.6)
            }
        }
        .opacity(0.6)
    }
}

// MARK: - Colors

extension Color {
    static let youColor = Color(red: 0.35, green: 0.55, blue: 0.75)    // muted blue
    static let themColor = Color(red: 0.82, green: 0.6, blue: 0.3)     // warm amber
    static let accentTeal = Color(red: 0.15, green: 0.55, blue: 0.55)  // deep teal
}
