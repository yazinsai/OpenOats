import AppKit
import Sparkle

/// Sparkle, trimmed from 1.x: same feed and key (Info.plist), menu check, App Management guidance.
@MainActor
final class Updater {
    static let shared = Updater()
    private let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: UserDriver(hostBundle: .main, delegate: nil), delegate: nil)

    /// Skipped unbundled (`swift run`) and in UI tests, where starting shows a modal error.
    func start() {
        guard Bundle.main.bundleIdentifier != nil, ProcessInfo.processInfo.environment["OPENOATS_UI_TEST"] == nil else { return }
        try? updater.start()
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}

/// macOS blocks replacing an app in /Applications until it's allowed under App Management; say so instead of Sparkle's
/// generic installer error.
final class UserDriver: SPUStandardUserDriver {
    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), Self.blocked(error as NSError) else {
            return super.showUpdaterError(error, acknowledgement: acknowledgement)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow OpenOats to Install Updates"
        alert.informativeText = """
        macOS blocked OpenOats from replacing the installed app. Open System Settings > Privacy & Security > \
        App Management, enable OpenOats, then try the update again.
        """
        alert.runModal()
        acknowledgement()
    }

    private static func blocked(_ error: NSError) -> Bool {
        let sparkle = error.domain == "SUSparkleErrorDomain"
        return (sparkle && error.code == 4012) || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
            || (sparkle && error.code == 4005 && error.localizedDescription.hasSuffix("Please try again later."))
            || ((error.userInfo[NSUnderlyingErrorKey] as? NSError).map(blocked) ?? false)
    }
}
