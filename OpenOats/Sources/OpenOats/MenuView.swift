import AppKit
import OatsCore
import SwiftUI

/// The menu bar panel: Start/Stop, elapsed time and level meters while recording, the Processing queue.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let recorder = model.recorder, let startedAt = model.startedAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let levels = recorder.levels
                    HStack(spacing: 10) {
                        Text(startedAt, style: .timer).monospacedDigit().frame(width: 56, alignment: .leading)
                        LevelMeter(label: "You", level: levels[.mic] ?? 0)
                        LevelMeter(label: "Them", level: levels[.system] ?? 0)
                    }
                }
                row("Stop Recording", shortcut: Hotkey.saved?.label) { model.stop() }
            } else {
                row("Start Recording", shortcut: Hotkey.saved?.label) { model.start() }
            }
            if !model.queue.isEmpty {
                Divider()
                Text("Processing").font(.caption).foregroundStyle(.secondary)
                ForEach(model.queue, id: \.id) { meeting in
                    HStack {
                        Text(meeting.title)
                        Spacer()
                        Text(meeting.id == model.processingID ? "Processing…" : "Waiting").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            row("Open OpenOats") { AppActions.openMainWindow() }
            row("Settings…") { AppActions.openSettings() }
            row("Check for Updates…") { Updater.shared.check() }
            Divider()
            row("Quit OpenOats") { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func row(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green).frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(height: 6)
        }
    }
}
