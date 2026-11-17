import AppKit
import OatsCore
import SwiftUI

/// The menu bar panel: Start/Stop, elapsed time and level meters while recording, the Processing queue.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The panel is key exactly while it is open (it closes when it loses focus); `onDisappear` doesn't fire on close.
    /// The meters, timer and Processing sweep only run while it is.
    @Environment(\.controlActiveState) private var active
    private var visible: Bool { active == .key }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let recorder = model.recorder, let startedAt = model.startedAt {
                    recording(recorder, since: startedAt).transition(Theme.rise)
                } else {
                    idle.transition(Theme.rise)
                }
            }
            .padding(Theme.s4)
            if let free = model.lowDiskSpace {
                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Low disk space").font(Theme.uiStrong).foregroundStyle(Theme.attention)
                        Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Recording stops below 200 MB.")
                            .font(Theme.meta).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .padding(Theme.s3).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .card(Theme.attention, radius: Theme.r2)
                    .padding([.horizontal, .bottom], Theme.s4)
                    .transition(Theme.rise)
            }
            if !model.queue.isEmpty { queue.transition(Theme.rise) }
            Theme.line.frame(height: 1)
            VStack(spacing: 0) {
                row("Open OpenOats", "macwindow", key: "o") { AppActions.openMainWindow() }
                row("Settings…", "gearshape", key: ",") { AppActions.openSettings() }
                row("Check for Updates…", "arrow.down.circle") { Updater.shared.check() }
                row("Quit OpenOats", "power", key: "q") { NSApp.terminate(nil) }
            }
            .padding(Theme.s1 + 2)
        }
        .frame(width: 300)
        .background(Theme.sidebar)
        .animation(Theme.gentle, value: model.recorder == nil)
        .animation(Theme.gentle, value: model.queue.map(\.id))
        .animation(Theme.gentle, value: model.lowDiskSpace == nil)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s3) {
                OatMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenOats").font(Theme.uiStrong).foregroundStyle(Theme.ink)
                    Text(model.queue.isEmpty ? "Ready when you are" : "Processing in the background").font(Theme.meta).foregroundStyle(Theme.ink2)
                }
            }
            startStop(recording: false)
        }
    }

    private func recording(_ recorder: Recorder, since startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .firstTextBaseline) {
                Label { Text("Recording") } icon: { Circle().fill(Theme.recording).frame(width: 8, height: 8) }
                    .font(Theme.eyebrow).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.recording)
                Spacer()
                // A live timer only while the panel shows; a hidden one would keep redrawing.
                Group {
                    if visible { Text(startedAt, style: .timer) } else {
                        Text(Duration.seconds(Date().timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                    }
                }
                .font(Theme.clock).foregroundStyle(Theme.ink).accessibilityLabel("Elapsed time")
            }
            VStack(spacing: Theme.s2) {
                LevelMeter(label: "Mic track", speaker: "You", running: visible) { recorder.levels[.mic] ?? 0 }
                LevelMeter(label: "System track", speaker: "Them", running: visible) { recorder.levels[.system] ?? 0 }
            }
            .padding(.bottom, Theme.s1)
            startStop(recording: true)
        }
    }

    private func startStop(recording: Bool) -> some View {
        Button {
            dismiss()
            recording ? model.stop() : model.start()
        } label: {
            HStack(spacing: Theme.s2) {
                ZStack {
                    Circle().fill(Theme.onFill).frame(width: 16, height: 16).opacity(recording ? 0 : 1)
                    RoundedRectangle(cornerRadius: recording ? 2 : 5, style: .continuous)
                        .fill(recording ? Theme.onFill : Theme.recording).frame(width: 10, height: 10)
                }
                Text(recording ? "Stop Recording" : "Start Recording")
                Spacer()
                if let key = Hotkey.saved?.label { Text(key).font(Theme.meta).opacity(0.75) }
            }
        }
        .buttonStyle(PillButtonStyle(tint: recording ? Theme.recording : Theme.accent, wide: true))
        .accessibilityLabel(recording ? "Stop Recording" : "Start Recording")
        .accessibilityHint(Hotkey.saved.map { "Shortcut \($0.label)" } ?? "")
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Processing").font(Theme.eyebrow).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.ink2)
            ForEach(model.queue, id: \.id) { meeting in
                let active = meeting.id == model.processingID
                VStack(alignment: .leading, spacing: Theme.s1 + 2) {
                    HStack(spacing: Theme.s2) {
                        Text(meeting.label).font(Theme.ui).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: Theme.s2)
                        Text(active ? "Processing" : "Waiting").font(Theme.meta).foregroundStyle(active ? Theme.accent : Theme.ink3)
                    }
                    if active { ProcessingBar(running: visible) }
                }
                .accessibilityElement(children: .combine)
                .transition(Theme.rise)
            }
        }
        .padding([.horizontal, .bottom], Theme.s4)
    }

    private func row(_ title: String, _ icon: String, key: KeyEquivalent? = nil, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(Theme.ink2)
                Text(title)
                Spacer()
                if let key { Text("⌘\(String(key.character).uppercased())").font(Theme.meta).foregroundStyle(Theme.ink3) }
            }
        }
        .buttonStyle(QuietButtonStyle())
        .keyboardShortcut(key.map { KeyboardShortcut($0) })
    }
}

/// One track's level as 24 segments, the last three amber. Core Animation layers moved by a 15 Hz timer that runs
/// only while the window is on screen, so a closed panel costs nothing and an open one stays cheap.
struct LevelMeter: View {
    let label: String
    let speaker: String
    let running: Bool
    let level: () -> Float

    var body: some View {
        HStack(spacing: Theme.s3) {
            Text(label).font(Theme.meta).foregroundStyle(Theme.ink2).frame(width: 78, alignment: .leading)
            Bar(running: running, level: level).frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level, \(speaker)")
    }

    private struct Bar: NSViewRepresentable {
        let running: Bool
        let level: () -> Float
        func makeNSView(context: Context) -> MeterView { MeterView(level: level) }
        func updateNSView(_ view: MeterView, context: Context) { view.running = running }
    }
}

final class MeterView: NSView {
    private static let segments = 24
    private let level: () -> Float
    private let track = CAShapeLayer(), clip = CALayer(), lit = CAGradientLayer(), litShape = CAShapeLayer()
    private var timer: Timer?
    var running = false { didSet { if running != oldValue { visibilityChanged() } } }

    init(level: @escaping () -> Float) {
        self.level = level
        super.init(frame: .zero)
        wantsLayer = true
        clip.masksToBounds = true
        lit.mask = litShape
        lit.startPoint = CGPoint(x: 0, y: 0.5)
        lit.endPoint = CGPoint(x: 1, y: 0.5)
        clip.addSublayer(lit)
        layer?.addSublayer(track)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let path = CGMutablePath(), n = CGFloat(Self.segments), gap: CGFloat = 2
        let width = (bounds.width - gap * (n - 1)) / n
        for i in 0..<Self.segments {
            path.addRoundedRect(in: CGRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: bounds.height), cornerWidth: 1.5, cornerHeight: 1.5)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, litShape] { shape.frame = bounds; shape.path = path }
        lit.frame = bounds
        lit.locations = [0, NSNumber(value: Double(Self.segments - 3) / Double(Self.segments)), NSNumber(value: Double(Self.segments - 3) / Double(Self.segments)), 1]
        CATransaction.commit()
        colors()
        tick()
    }

    override func viewDidChangeEffectiveAppearance() { colors() }

    private func colors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.fillColor = NSColor(Theme.raised).cgColor
            let accent = NSColor(Theme.accent).cgColor, amber = NSColor(Theme.attention).cgColor
            lit.colors = [accent, accent, amber, amber]
        }
    }

    override func viewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        visibilityChanged()
    }

    @objc private func visibilityChanged() {
        timer?.invalidate()
        timer = nil
        guard running, let window, window.occlusionState.contains(.visible) else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let n = CGFloat(Self.segments), step = (bounds.width + 2) / n
        let lit = (CGFloat(level()).squareRoot() * n).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = CGRect(x: 0, y: 0, width: lit * step, height: bounds.height)
        CATransaction.commit()
    }
}

/// Processing in progress: a soft moss sweep while `running` (and Reduce Motion is off), a still track otherwise.
struct ProcessingBar: View {
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || Theme.reduceMotion)) { timeline in
            GeometryReader { geo in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let width = geo.size.width * 0.35
                Capsule().fill(Theme.raised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(running ? 1 : 0.35))
                            .frame(width: running && !Theme.reduceMotion ? width : geo.size.width * (running ? 1 : 0.0))
                            .offset(x: running && !Theme.reduceMotion ? (geo.size.width + width) * phase - width : 0)
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// The OpenOats mark, as in the app icon: two concentric white rings on a black tile.
struct OatMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(.black)
            .overlay {
                ZStack {
                    // Ring centrelines and widths measured from AppIcon.png (1024 px).
                    Circle().strokeBorder(.white, lineWidth: size * 0.081).frame(width: size * 0.664, height: size * 0.664)
                    Circle().strokeBorder(.white, lineWidth: size * 0.07).frame(width: size * 0.344, height: size * 0.344)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
