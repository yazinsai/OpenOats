import SwiftUI

/// The one onboarding screen, shown at launch until the recording-consent acknowledgement is stored.
struct OnboardingView: View {
    static let windowID = "onboarding"
    @StateObject private var model = SettingsModel()
    @ObservedObject private var app = AppModel.shared
    @State private var consent = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to OpenOats").font(.title2.bold())
            Text("OpenOats records your meetings and writes a Meeting file to your notes folder. By default everything stays on this Mac.")
                .foregroundStyle(.secondary)
            step("Microphone", model.mic == .denied ? "Allow OpenOats in System Settings › Privacy & Security › Microphone." : "Records You.",
                 done: model.mic == .authorized, button: "Allow", action: model.requestMic)
            step("System audio", model.systemAudio.flatMap { $0.isEmpty ? nil : $0 } ?? "Records Them, from your meeting app.",
                 done: model.systemAudio == "", button: model.systemAudio == nil ? "Allow" : "Try Again", action: model.requestSystemAudio)
            step("Notes folder", model.settings.notesFolder.path(percentEncoded: false), done: false, button: "Choose…",
                 action: model.chooseNotesFolder)
            Toggle("I'll tell people when I record them, as the law where I live requires.", isOn: $consent)
                .accessibilityIdentifier("onboarding.consent")
            HStack {
                if let status = app.modelDownload { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") {
                    app.onboarded = true
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .accessibilityIdentifier("onboarding.root")
        .onAppear { app.downloadModel() }
    }

    private func step(_ title: String, _ detail: String, done: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { Button(button, action: action) }
        }
    }
}
