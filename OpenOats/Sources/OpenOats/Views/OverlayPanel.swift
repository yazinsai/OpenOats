import AppKit
import SwiftUI

/// A floating NSPanel that is invisible to screen sharing.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, defaults: UserDefaults = .standard, alwaysOnTop: Bool = true) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
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

    /// Update the always-on-top state of an existing panel.
    func applyAlwaysOnTop(_ enabled: Bool) {
        isFloatingPanel = enabled
        level = enabled ? .floating : .normal
    }
}

/// Manages the floating suggestion side panel lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    private var panel: OverlayPanel?
    private var sidecastPanel: OverlayPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var sidecastHostingView: NSHostingView<AnyView>?
    var defaults: UserDefaults = .standard

    // Classic suggestions panel dimensions
    private static let classicWidth: CGFloat = 250
    private static let classicMinHeight: CGFloat = 100
    private static let classicMaxHeight: CGFloat = 400

    // Sidecast sidebar dimensions
    private static let sidecastDefaultWidth: CGFloat = 380
    private static let sidecastMinWidth: CGFloat = 300
    private static let sidecastMaxWidth: CGFloat = 550

    func showSidePanel<Content: View>(content: Content) {
        let erased = AnyView(content)

        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            let rect = NSRect(
                x: screenFrame.maxX - Self.classicWidth - 12,
                y: screenFrame.midY - Self.classicMaxHeight / 2,
                width: Self.classicWidth,
                height: Self.classicMaxHeight
            )
            let alwaysOnTop = defaults.object(forKey: "suggestionsAlwaysOnTop") == nil
                ? true
                : defaults.bool(forKey: "suggestionsAlwaysOnTop")
            let newPanel = OverlayPanel(contentRect: rect, defaults: defaults, alwaysOnTop: alwaysOnTop)
            newPanel.minSize = NSSize(width: Self.classicWidth, height: Self.classicMinHeight)
            newPanel.maxSize = NSSize(width: Self.classicWidth + 100, height: Self.classicMaxHeight)
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

    /// Show the full-height sidecast sidebar docked to the right edge.
    func showSidecastSidebar<Content: View>(content: Content) {
        let erased = AnyView(content)

        if sidecastPanel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            // Full height, docked to right edge
            let rect = NSRect(
                x: screenFrame.maxX - Self.sidecastDefaultWidth,
                y: screenFrame.minY,
                width: Self.sidecastDefaultWidth,
                height: screenFrame.height
            )
            let newPanel = OverlayPanel(contentRect: rect, defaults: defaults)
            newPanel.minSize = NSSize(width: Self.sidecastMinWidth, height: 300)
            newPanel.maxSize = NSSize(width: Self.sidecastMaxWidth, height: screenFrame.height)
            newPanel.setFrameAutosaveName("SidecastSidebar")
            sidecastPanel = newPanel
        }

        if let sidecastHostingView {
            sidecastHostingView.rootView = erased
        } else {
            let newHostingView = NSHostingView(rootView: erased)
            sidecastHostingView = newHostingView
            sidecastPanel?.contentView = newHostingView
        }
        sidecastPanel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        // Clear the SwiftUI content so the NSHostingView stops participating
        // in the 60Hz display cycle (observation tracking + layout) while hidden.
        hostingView?.rootView = AnyView(EmptyView())

        sidecastPanel?.orderOut(nil)
        sidecastHostingView?.rootView = AnyView(EmptyView())
    }

    func toggle<Content: View>(content: Content) {
        if panel?.isVisible == true {
            hide()
        } else {
            showSidePanel(content: content)
        }
    }

    func toggleSidecast<Content: View>(content: Content) {
        if sidecastPanel?.isVisible == true {
            sidecastPanel?.orderOut(nil)
            sidecastHostingView?.rootView = AnyView(EmptyView())
        } else {
            showSidecastSidebar(content: content)
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true || sidecastPanel?.isVisible == true
    }

    /// Update the always-on-top state for the classic suggestions panel.
    func updateAlwaysOnTop(_ enabled: Bool) {
        panel?.applyAlwaysOnTop(enabled)
    }

    /// Hide after a delay (used for session end).
    func hideAfterDelay(seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            hide()
        }
    }
}
