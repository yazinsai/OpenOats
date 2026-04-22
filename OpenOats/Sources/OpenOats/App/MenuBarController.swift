import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let coordinator: AppCoordinator
    private let settings: AppSettings
    private let onToggleMeeting: () -> Void
    private var iconUpdateTask: Task<Void, Never>?

    var onShowMainWindow: (() -> Void)?
    var onQuitApp: (() -> Void)?

    init(
        coordinator: AppCoordinator,
        settings: AppSettings,
        onCheckForUpdates: @escaping () -> Void,
        onToggleMeeting: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.onToggleMeeting = onToggleMeeting

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.behavior = .transient
        popover.animates = true

        let popoverView = MenuBarPopoverView(
            coordinator: coordinator,
            settings: settings,
            onToggleMeeting: onToggleMeeting,
            onShowMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.onShowMainWindow?()
            },
            onCheckForUpdates: { [weak self] in
                self?.popover.performClose(nil)
                onCheckForUpdates()
            },
            onShowSettings: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            onQuit: { [weak self] in
                self?.popover.performClose(nil)
                self?.onQuitApp?()
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)

        if let button = statusItem.button {
            button.image = Self.makeConcentricCirclesIcon(filled: false)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        startIconObservation()
    }

    deinit {
        iconUpdateTask?.cancel()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func startIconObservation() {
        iconUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                updateIcon()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.coordinator.isRecording
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = Self.makeConcentricCirclesIcon(filled: coordinator.isRecording)
        statusItem.button?.image?.isTemplate = true
    }

    private static func makeConcentricCirclesIcon(filled: Bool) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let outerRadius: CGFloat = size / 2 - 1
            let ringWidth: CGFloat = 2.2
            let innerRadius: CGFloat = outerRadius * 0.38

            NSColor.black.setStroke()

            // Outer ring
            let outerPath = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - outerRadius,
                    y: center.y - outerRadius,
                    width: outerRadius * 2,
                    height: outerRadius * 2
                )
            )
            outerPath.lineWidth = ringWidth
            if filled {
                NSColor.black.setFill()
                outerPath.fill()
                // Draw inner part in white to create ring effect
                let gapRadius = outerRadius - ringWidth
                let gapPath = NSBezierPath(
                    ovalIn: NSRect(
                        x: center.x - gapRadius,
                        y: center.y - gapRadius,
                        width: gapRadius * 2,
                        height: gapRadius * 2
                    )
                )
                NSColor.white.setFill()
                gapPath.fill()
                // Inner filled circle
                let innerPath = NSBezierPath(
                    ovalIn: NSRect(
                        x: center.x - innerRadius,
                        y: center.y - innerRadius,
                        width: innerRadius * 2,
                        height: innerRadius * 2
                    )
                )
                NSColor.black.setFill()
                innerPath.fill()
            } else {
                outerPath.stroke()
                // Inner ring
                let innerPath = NSBezierPath(
                    ovalIn: NSRect(
                        x: center.x - innerRadius,
                        y: center.y - innerRadius,
                        width: innerRadius * 2,
                        height: innerRadius * 2
                    )
                )
                innerPath.lineWidth = ringWidth
                innerPath.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenOats"
        return image
    }
}
