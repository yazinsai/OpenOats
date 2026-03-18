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
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
                .frame(height: 52)

            Spacer().frame(height: 20)

            Text("Recording Consent Notice")
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            Text("""
            OpenOats records and transcribes audio from your microphone \
            and system audio during meetings. Many jurisdictions require \
            all-party consent before recording a conversation.

            By using this app, you acknowledge that:
            """)
                .font(.system(size: 13))
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

            Toggle(isOn: $acknowledged) {
                Text("I understand and accept these obligations")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)

            Spacer()

            HStack {
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    settings.hasAcknowledgedRecordingConsent = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                } label: {
                    Text("I Agree")
                        .font(.system(size: 13, weight: .medium))
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
            Text("\u{2022}")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
