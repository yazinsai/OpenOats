import AppKit
import SwiftUI

/// A slim, draggable floating bar that appears during active meetings.
/// Unlike the full OverlayPanel, this is a compact pill showing waveform
/// and suggestion bubbles.
final class MiniBarPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
        sharingType = hidden ? .none : .readOnly
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setFrameAutosaveName("MiniBarPanel")
    }
}

/// Manages the mini bar panel lifecycle.
@MainActor
final class MiniBarManager: ObservableObject {
    private var panel: MiniBarPanel?
    var defaults: UserDefaults = .standard

    func show<Content: View>(content: Content) {
        if panel == nil {
            // Position near bottom-center of main screen
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let barWidth: CGFloat = 56
            let barHeight: CGFloat = 200
            let x = screenFrame.midX - barWidth / 2
            let y = screenFrame.minY + 80
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            panel = MiniBarPanel(contentRect: rect, defaults: defaults)
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.layer?.cornerRadius = 28
        hostingView.layer?.masksToBounds = true
        panel?.contentView = hostingView
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }
}
