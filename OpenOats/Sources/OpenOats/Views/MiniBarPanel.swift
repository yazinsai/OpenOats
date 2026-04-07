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

/// Observable state model for the mini bar. Mutations drive SwiftUI updates
/// without recreating the view hierarchy.
@Observable
@MainActor
final class MiniBarState {
    var audioLevel: Float = 0
    var suggestions: [Suggestion] = []
    var isGenerating: Bool = false
    /// Not observed — assigning a new closure should not trigger SwiftUI invalidation.
    @ObservationIgnored var onTap: () -> Void = {}
}

/// Manages the mini bar panel lifecycle.
/// The NSHostingView is created once; subsequent updates mutate `state`.
@MainActor
final class MiniBarManager: ObservableObject {
    private var panel: MiniBarPanel?
    private var hostingView: NSHostingView<AnyView>?
    let state = MiniBarState()
    var defaults: UserDefaults = .standard

    func show() {
        if panel == nil {
            // Position near bottom-center of main screen
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let barWidth: CGFloat = 40
            let barHeight: CGFloat = 18
            let x = screenFrame.midX - barWidth / 2
            let y = screenFrame.minY + 40
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            panel = MiniBarPanel(contentRect: rect, defaults: defaults)

            let hv = NSHostingView(rootView: AnyView(MiniBarContent(state: state)))
            hv.layer?.cornerRadius = 9
            hv.layer?.masksToBounds = true
            panel?.contentView = hv
            hostingView = hv
        } else {
            // Restore live content if it was cleared on hide.
            hostingView?.rootView = AnyView(MiniBarContent(state: state))
        }
        if panel?.isVisible != true {
            panel?.orderFront(nil)
        }
    }

    func update(audioLevel: Float, suggestions: [Suggestion], isGenerating: Bool) {
        state.audioLevel = audioLevel
        state.suggestions = suggestions
        state.isGenerating = isGenerating
    }

    func hide() {
        panel?.orderOut(nil)
        // Clear SwiftUI content so the NSHostingView stops participating in the
        // 60Hz display cycle (observation tracking + layout) while hidden.
        hostingView?.rootView = AnyView(EmptyView())
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }
}
