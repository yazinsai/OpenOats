import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let liveSessionController: LiveSessionController
    private var iconUpdateTask: Task<Void, Never>?

    var onShowMainWindow: (() -> Void)?
    var onQuitApp: (() -> Void)?

    init(
        liveSessionController: LiveSessionController,
        meetingDetectionController: MeetingDetectionController,
        settings: SettingsStore,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.liveSessionController = liveSessionController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.behavior = .transient
        popover.animates = true

        let popoverView = MenuBarPopoverView(
            liveSessionController: liveSessionController,
            meetingDetectionController: meetingDetectionController,
            settings: settings,
            onShowMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.onShowMainWindow?()
            },
            onCheckForUpdates: { [weak self] in
                self?.popover.performClose(nil)
                onCheckForUpdates()
            },
            onQuit: { [weak self] in
                self?.popover.performClose(nil)
                self?.onQuitApp?()
            }
        )
        popover.contentViewController = NSHostingController(rootView: popoverView)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "OpenOats")
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
        iconUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateIcon()
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.liveSessionController.state.hasActiveSession
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func updateIcon() {
        let symbolName = liveSessionController.state.hasActiveSession
            ? "waveform.circle.fill"
            : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "OpenOats"
        )
        statusItem.button?.image?.isTemplate = true
    }
}
