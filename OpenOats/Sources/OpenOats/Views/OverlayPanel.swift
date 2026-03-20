import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
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

        // Remember position
        setFrameAutosaveName("OverlayPanel")
    }
}

/// Manages the overlay panel lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    private var panel: OverlayPanel?
    var defaults: UserDefaults = .standard

    func show<Content: View>(content: Content) {
        if panel == nil {
            let rect = NSRect(x: 100, y: 100, width: 400, height: 300)
            panel = OverlayPanel(contentRect: rect, defaults: defaults)
        }

        let hostingView = NSHostingView(rootView: content)
        panel?.contentView = hostingView
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle<Content: View>(content: Content) {
        if panel?.isVisible == true {
            hide()
        } else {
            show(content: content)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }
}
