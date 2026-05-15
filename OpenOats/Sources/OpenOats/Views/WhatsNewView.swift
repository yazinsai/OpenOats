import SwiftUI

struct WhatsNewView: View {
    let release: WhatsNewRelease
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New in OpenOats \(release.version)")
                    .font(.system(size: 24, weight: .semibold))
                Text(release.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(markdownText)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            .frame(minHeight: 260, maxHeight: 420)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("View Full Release Notes") {
                    openURL(release.htmlURL)
                    onClose()
                }
                .buttonStyle(.link)

                Spacer()

                Button("Got It") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private var markdownText: AttributedString {
        (try? AttributedString(markdown: release.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(release.body)
    }
}
