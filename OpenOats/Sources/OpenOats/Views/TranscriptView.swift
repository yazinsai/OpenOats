import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String
    var showSearch: Bool = false

    @State private var searchText = ""
    @State private var autoScrollEnabled = true

    private var filteredUtterances: [Utterance] {
        guard !searchText.isEmpty else { return utterances }
        return utterances.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isSearching: Bool {
        showSearch && !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
                Divider()
            }
            transcriptScrollView
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search transcript…", text: $searchText)
.accessibilityLabel(String(localized: "textfield_search_transcript…_label"))
                .textFieldStyle(.plain)
                .font(.footnote)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "clear_search"))
            }

            Divider()
                .frame(height: 14)

            Button {
                autoScrollEnabled.toggle()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(autoScrollEnabled ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
            .help(autoScrollEnabled ? "Pause auto-scroll" : "Resume auto-scroll")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let visible = filteredUtterances
                if visible.isEmpty && isSearching {
                    Text(String(localized: "no_matches"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, utterance in
                            UtteranceBubble(
                                utterance: utterance,
                                showTimestamp: shouldShowTimestamp(at: index, in: visible)
                            )
                            .id(utterance.id)
                        }

                        if !isSearching {
                            if !volatileYouText.isEmpty {
                                VolatileIndicator(text: volatileYouText, speaker: .you)
                                    .id("volatile-you")
                            }

                            if !volatileThemText.isEmpty {
                                VolatileIndicator(text: volatileThemText, speaker: .them)
                                    .id("volatile-them")
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .onChange(of: utterances.count) {
                guard !isSearching, autoScrollEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = utterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                guard !isSearching, autoScrollEnabled else { return }
                proxy.scrollTo("volatile-you", anchor: .bottom)
            }
            .onChange(of: volatileThemText) {
                guard !isSearching, autoScrollEnabled else { return }
                proxy.scrollTo("volatile-them", anchor: .bottom)
            }
            .onChange(of: searchText) {
                if searchText.isEmpty, autoScrollEnabled, let last = utterances.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScrollEnabled {
                    Button {
                        autoScrollEnabled = true
                        if let last = utterances.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentTeal)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "resume_autoscroll"))
                    .padding(12)
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
    }

    private func shouldShowTimestamp(at index: Int, in visible: [Utterance]) -> Bool {
        guard index > 0 else { return true }
        let current = Calendar.current.dateComponents([.hour, .minute], from: visible[index].timestamp)
        let previous = Calendar.current.dateComponents([.hour, .minute], from: visible[index - 1].timestamp)
        return current.hour != previous.hour || current.minute != previous.minute
    }
}

// MARK: - Timestamp Formatter

private let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private struct UtteranceBubble: View {
    let utterance: Utterance
    var showTimestamp: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTimestamp {
                Text(timestampFormatter.string(from: utterance.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 34)
            }

            Text(utterance.speaker.displayLabel)
                .font(.caption)
                .foregroundStyle(utterance.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            Text(utterance.displayText)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer()
                .frame(width: 34)

            Text(speaker.displayLabel)
                .font(.caption)
                .foregroundStyle(speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(text)
                    .font(.subheadline)
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
