import SwiftUI

struct TranscriptWindowView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let store = coordinator.transcriptStore
        VStack(spacing: 0) {
            HStack {
                Text("Live Transcript")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !store.utterances.isEmpty {
                    Button {
                        copyTranscript(store.utterances)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy transcript to clipboard")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            TranscriptView(
                utterances: store.utterances,
                volatileYouText: store.volatileYouText,
                volatileThemText: store.volatileThemText,
                showSearch: true
            )
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    private func copyTranscript(_ utterances: [Utterance]) {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
