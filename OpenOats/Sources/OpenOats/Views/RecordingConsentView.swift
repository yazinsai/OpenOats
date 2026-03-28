import SwiftUI

/// Modal sheet requiring users to acknowledge their obligation to comply with
/// applicable recording consent laws before using the transcription feature.
struct RecordingConsentView: View {
    @Binding var isPresented: Bool
    @Bindable var settings: AppSettings
    @State private var acknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "exclamationmark.shield")
                .font(.title)
                .foregroundStyle(.orange)
                .frame(height: 52)

            Spacer().frame(height: 20)

            Text(String(localized: "recording_consent_notice"))
                .font(.body)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            Text("""
            OpenOats records and transcribes audio from your microphone \
            and system audio during meetings. Many jurisdictions require \
            all-party consent before recording a conversation.

            By using this app, you acknowledge that:
            """)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 8) {
                consentBullet("You are solely responsible for obtaining any required consent from all participants before recording.")
                consentBullet("You will comply with all applicable local, state, and federal laws governing recording and wiretapping.")
                consentBullet("The developers of OpenOats accept no liability for unauthorized or unlawful recording.")
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 16)

            Toggle(isOn: $acknowledged)
.accessibilityHint(String(localized: "toggle_accessibility_hint")) {
                Text(String(localized: "i_understand_and_accept_these_obligations"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            Spacer()

            HStack {
                Button(String(localized: "cancel")) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
.accessibilityLabel(String(localized: "cancel"))
.accessibilityHint(String(localized: "cancel_action_hint"))
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    settings.hasAcknowledgedRecordingConsent = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                } label: {
                    Text(String(localized: "i_agree"))
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            acknowledged ? Color.accentTeal : Color.gray,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!acknowledged)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func consentBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(String(localized: "u2022"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
