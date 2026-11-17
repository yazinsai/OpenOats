import Foundation
import IOKit
import IOKit.pwr_mgt

/// Observes system sleep and wake through IOKit power management.
///
/// `NSWorkspace.willSleepNotification` only tells the app that sleep is
/// coming; the Mac does not wait for anyone. IOKit's power notifications let
/// the app hold off sleep (the system waits up to about 30 seconds) until it
/// acknowledges, which is the window needed to stop a recording and finish
/// writing the session before the machine freezes.
@MainActor
final class SystemPowerMonitor {
    /// Called when the system is about to sleep. Call `allowSleep` once the
    /// app is ready; sleep is held until then (or until the system gives up).
    var onWillSleep: ((_ allowSleep: @escaping @MainActor () -> Void) -> Void)?
    /// Called once the system has woken and is running again.
    var onDidWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // iokit_common_msg(...) values from IOKit/IOMessage.h; the C macros are
    // not imported into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    func start() {
        guard rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon,
            &notificationPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let notificationID = Int(bitPattern: messageArgument)
                // The run loop source is on the main run loop.
                MainActor.assumeIsolated {
                    monitor.handle(messageType: messageType, notificationID: notificationID)
                }
            },
            &notifier
        )
        guard rootPort != 0, let notificationPort else {
            Log.power.error("IORegisterForSystemPower failed; sleep handling disabled")
            rootPort = 0
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .commonModes
        )
    }

    func stop() {
        guard rootPort != 0 else { return }
        if let notificationPort {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
                .commonModes
            )
        }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        rootPort = 0
        notificationPort = nil
        notifier = 0
    }

    private func handle(messageType: UInt32, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            // Idle sleep request. Never veto it.
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            let port = rootPort
            var acknowledged = false
            let allowSleep: @MainActor () -> Void = {
                guard !acknowledged else { return }
                acknowledged = true
                IOAllowPowerChange(port, notificationID)
            }
            if let onWillSleep {
                onWillSleep(allowSleep)
            } else {
                allowSleep()
            }
        case Self.systemHasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }
}
