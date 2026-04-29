import AppKit
import SwiftUI

/// Screen 4: confirm the resolved setup and finish.
struct ConfirmationStepView: View {
    @Bindable var viewModel: WizardViewModel
    let settings: SettingsStore
    let onComplete: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasBackButton {
                HStack {
                    Button {
                        viewModel.goBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .medium))
                            Text("Back")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentTeal)

            Spacer().frame(height: 16)

            narrativeText

            Spacer().frame(height: 16)

            if let recommendation = viewModel.recommendation {
                Text(recommendation.summaryLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 8)

                downloadSizeText(bytes: recommendation.estimatedDownloadBytes)

                Spacer().frame(height: 12)

                DisclosureGroup("Show details", isExpanded: $viewModel.showDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recommendation.detailLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            }

            Spacer().frame(height: 20)

            micPermissionSection

            Spacer()

            VStack(spacing: 8) {
                Button {
                    viewModel.applySettings(to: settings)
                    onComplete()
                } label: {
                    Text("Get started")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.canAdvance ? Color.accentTeal : Color.gray.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canAdvance)

                Button("Customize models manually") {
                    onCustomize()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(28)
    }

    // MARK: - Narrative

    @ViewBuilder
    private var narrativeText: some View {
        let isTranscriptOnly = viewModel.intent == .transcribe
        let isLocal = viewModel.recommendation?.profile.isLocal ?? false

        VStack(spacing: 8) {
            if isTranscriptOnly {
                Text("You're all set. When your next call starts, OpenOats will notice and ask if you'd like to record. Say yes, and it transcribes every word of the conversation in real time.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            } else {
                Text("You're all set. When your next Zoom, Meet, or Teams call starts, OpenOats will notice and ask if you'd like to record. Say yes, and it transcribes the conversation and generates notes with action items when you're done.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            if isLocal {
                Text("Everything runs on your Mac. Nothing leaves this computer.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentTeal)
            }
        }
    }

    // MARK: - Download Size

    @ViewBuilder
    private func downloadSizeText(bytes: Int64) -> some View {
        if bytes == 0 {
            Text("No downloads needed. Ready to go.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if bytes < 500_000_000 {
            Text("Small download (~\(bytes / 1_000_000) MB) - about a minute on most connections")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if bytes < 1_500_000_000 {
            Text("Medium download (~\(String(format: "%.1f", Double(bytes) / 1_000_000_000)) GB) - a few minutes on most connections")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("Large download (~\(String(format: "%.1f", Double(bytes) / 1_000_000_000)) GB) - may take 5-10 minutes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mic Permission

    @ViewBuilder
    private var micPermissionSection: some View {
        switch viewModel.micPermission {
        case .authorized:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Microphone access granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

        case .notDetermined:
            VStack(spacing: 8) {
                Text("One last thing: OpenOats needs microphone access to transcribe your meetings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Grant access") {
                    Task { await viewModel.requestMicPermission() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(OpenOatsProminentButtonStyle())
                .controlSize(.small)
            }

        case .denied, .restricted:
            VStack(spacing: 8) {
                Text("Microphone access was previously denied. OpenOats needs it to transcribe.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Check again") {
                        viewModel.recheckMicPermission()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
