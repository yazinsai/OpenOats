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

/// Manages the floating suggestion side panel lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<AnyView>?
    var defaults: UserDefaults = .standard
    private static let panelWidth: CGFloat = 250
    private static let panelMinHeight: CGFloat = 100
    private static let panelMaxHeight: CGFloat = 400

    func showSidePanel<Content: View>(content: Content) {
        let erased = AnyView(content)

        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            // Dock to right edge of screen
            let rect = NSRect(
                x: screenFrame.maxX - Self.panelWidth - 12,
                y: screenFrame.midY - Self.panelMaxHeight / 2,
                width: Self.panelWidth,
                height: Self.panelMaxHeight
            )
            let newPanel = OverlayPanel(contentRect: rect, defaults: defaults)
            newPanel.minSize = NSSize(width: Self.panelWidth, height: Self.panelMinHeight)
            newPanel.maxSize = NSSize(width: Self.panelWidth + 100, height: Self.panelMaxHeight)
            newPanel.setFrameAutosaveName("SuggestionSidePanel")
            panel = newPanel
        }

        if let hostingView {
            hostingView.rootView = erased
        } else {
            let newHostingView = NSHostingView(rootView: erased)
            hostingView = newHostingView
            panel?.contentView = newHostingView
        }
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle<Content: View>(content: Content) {
        if panel?.isVisible == true {
            hide()
        } else {
            showSidePanel(content: content)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// Hide after a delay (used for session end).
    func hideAfterDelay(seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            hide()
        }
    }
}
