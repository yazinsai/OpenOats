import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    var emptyStateMessage: String? = nil
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
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search transcript…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Divider()
                .frame(height: 14)

            Button {
                autoScrollEnabled.toggle()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11))
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
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else if visible.isEmpty,
                          !isSearching,
                          volatileYouText.isEmpty,
                          volatileThemText.isEmpty,
                          let emptyStateMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text(emptyStateMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .padding(16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<visible.count, id: \.self) { index in
                            let utterance = visible[index]
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
                            .font(.system(size: 20))
                            .foregroundStyle(.white, Color.accentTeal)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Resume auto-scroll")
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
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 34)
            }

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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer()
                .frame(width: 34)

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
