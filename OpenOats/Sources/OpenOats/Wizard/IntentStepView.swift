import SwiftUI

/// Screen 1: choose the user-facing outcome.
struct IntentStepView: View {
    @Bindable var viewModel: WizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("What do you want OpenOats to do?")
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("wizard.intent.title")

            Spacer().frame(height: 8)

            Text("You can always change this later in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer().frame(height: 28)

            VStack(spacing: 12) {
                intentCard(
                    intent: .transcribe,
                    icon: "waveform",
                    title: "Transcribe",
                    description: "See every word of your conversation in real time",
                    isSelected: viewModel.intent == .transcribe
                )

                intentCard(
                    intent: .notes,
                    icon: "doc.text",
                    title: "Meeting notes",
                    description: "Get meeting notes and action items automatically",
                    isSelected: viewModel.intent == .notes
                )

                intentCard(
                    intent: .fullCopilot,
                    icon: "sparkles",
                    title: "Full copilot",
                    description: "Real-time talking points pulled from your own notes",
                    isSelected: viewModel.intent == .fullCopilot
                )
            }
            .padding(.horizontal, 4)

            Spacer()

            if viewModel.snapshot.hasOpenRouterKey || viewModel.snapshot.hasVoyageKey {
                Text("Cloud API key detected. Full copilot is the fastest path.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }

            HStack {
                Spacer()

                Button {
                    viewModel.advance()
                } label: {
                    HStack(spacing: 6) {
                        Text("Next")
                            .font(.system(size: 13, weight: .medium))
                        if viewModel.isDetecting {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.canAdvance ? Color.accentTeal : Color.gray.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canAdvance)
                .accessibilityIdentifier("wizard.intent.next")
            }
        }
        .padding(28)
    }

    private func intentCard(
        intent: WizardIntent,
        icon: String,
        title: String,
        description: String,
        isSelected: Bool
    ) -> some View {
        Button {
            viewModel.intent = intent
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentTeal : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentTeal)
                        .font(.system(size: 16))
                }
            }
            .contentShape(Rectangle())
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentTeal.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentTeal.opacity(0.4) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
