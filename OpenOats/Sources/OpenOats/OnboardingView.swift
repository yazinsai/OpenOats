import SwiftUI

/// The one onboarding screen, shown at launch until the recording-consent acknowledgement is stored.
struct OnboardingView: View {
    static let windowID = "onboarding"
    @ObservedObject var model: SettingsModel
    @ObservedObject private var app = AppModel.shared
    @State private var consent = false
    @State private var appeared = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OatMark(size: 44).padding(.bottom, Theme.s4)
            Text("Welcome to OpenOats").font(Theme.display).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Text("OpenOats records your meetings and writes a Meeting file to your notes folder. By default everything stays on this Mac.")
                .font(Theme.ui).foregroundStyle(Theme.ink2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s2).padding(.bottom, Theme.s5)
            VStack(spacing: 0) {
                step(1, "Microphone", model.mic == .denied ? "Allow OpenOats in System Settings › Privacy & Security › Microphone." : "Records You, on the Mic track.",
                     done: model.mic == .authorized, button: "Allow", action: model.requestMic)
                Theme.line.frame(height: 1).padding(.leading, 56)
                step(2, "System audio", model.systemAudio.flatMap { $0.isEmpty ? nil : $0 } ?? "Records Them, from your meeting app, on the System track.",
                     done: model.systemAudio == "", button: model.systemAudio == nil ? "Allow" : "Try Again", action: model.requestSystemAudio)
                Theme.line.frame(height: 1).padding(.leading, 56)
                step(3, "Notes folder", model.settings.notesFolder.path(percentEncoded: false), done: false, button: "Choose…",
                     action: model.chooseNotesFolder)
            }
            .background(RoundedRectangle(cornerRadius: Theme.r3, style: .continuous).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: Theme.r3, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            Toggle(isOn: $consent.animation(Theme.snappy)) {
                Text("I'll tell people when I record them, as the law where I live requires.")
                    .font(Theme.ui).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox).tint(Theme.accent)
            .accessibilityIdentifier("onboarding.consent")
            .padding(.top, Theme.s5)
            HStack(spacing: Theme.s2) {
                if let status = app.modelDownload {
                    Image(systemName: status.hasSuffix("ready.") ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(status.hasSuffix("ready.") ? Theme.accent : Theme.ink3)
                    Text(status).font(Theme.meta).foregroundStyle(Theme.ink2).transition(.opacity)
                }
                Spacer()
                Button("Done") {
                    app.onboarded = true
                    dismissWindow(id: Self.windowID)
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
            }
            .padding(.top, Theme.s6)
            .animation(Theme.gentle, value: app.modelDownload)
        }
        .padding([.horizontal, .bottom], Theme.s6).padding(.top, Theme.s3)
        .frame(width: 520)
        .background(Theme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
        .onAppear {
            app.downloadModel()
            withAnimation(Theme.gentle) { appeared = true }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, done: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.s4) {
            ZStack {
                Circle().strokeBorder(Theme.line, lineWidth: 1.5).opacity(done ? 0 : 1)
                Text("\(n)").font(Theme.meta.weight(.semibold)).foregroundStyle(Theme.ink2).opacity(done ? 0 : 1)
                if done {
                    Circle().fill(Theme.accent)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onFill)
                        .transition(Theme.reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
            .animation(Theme.lively, value: done)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.uiStrong).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.meta).foregroundStyle(Theme.ink2)
                    .lineLimit(n == 3 ? 1 : 3).truncationMode(n == 3 ? .middle : .tail).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.s2)
            if done {
                Text("Allowed").font(Theme.meta.weight(.medium)).foregroundStyle(Theme.accent).transition(.opacity)
            } else {
                Button(button, action: action).buttonStyle(PillButtonStyle(filled: false)).controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
        .accessibilityElement(children: .contain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || Theme.reduceMotion ? 0 : 8)
        .animation(Theme.gentle.delay(0.06 * Double(n)), value: appeared)
    }
}
