import Foundation

/// An app whose Calls OpenOats asks to record. Matched by the bundle ID of the process doing the audio, not by
/// whether the app is merely running: helpers (`<id>.helper`, `com.apple.WebKit.GPU`) count as their app.
public struct CallApp: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    let bundleIDs: [String]

    init(_ name: String, _ bundleIDs: String...) {
        self.id = bundleIDs[0]
        self.name = name
        self.bundleIDs = bundleIDs
    }

    /// Native call apps and browsers (a Meet, Teams or Zoom tab). Dictation and AI voice apps are left out on purpose:
    /// an allowlist of who holds the mic replaces 1.x's ever-growing list of apps to ignore.
    public static let known: [CallApp] = [
        CallApp("Zoom", "us.zoom.xos"),
        CallApp("Microsoft Teams", "com.microsoft.teams2", "com.microsoft.teams"),
        CallApp("FaceTime", "com.apple.FaceTime", "com.apple.avconferenced"),
        CallApp("Webex", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"),
        CallApp("Slack", "com.tinyspeck.slackmacgap"),
        CallApp("Discord", "com.hnc.Discord"),
        CallApp("WhatsApp", "net.whatsapp.WhatsApp", "desktop.WhatsApp"),
        CallApp("Signal", "org.whispersystems.signal-desktop"),
        CallApp("Telegram", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"),
        CallApp("Skype", "com.skype.skype"),
        CallApp("Tuple", "app.tuple.app"),
        CallApp("Around", "co.around.Around"),
        CallApp("OpenPhone", "ca.illusive.openphone"),
        CallApp("kMeet", "com.infomaniak.meet"),
        CallApp("Google Chrome", "com.google.Chrome"),
        CallApp("Arc", "company.thebrowser.Browser"),
        CallApp("Dia", "company.thebrowser.dia"),
        CallApp("Brave", "com.brave.Browser"),
        CallApp("Microsoft Edge", "com.microsoft.edgemac"),
        CallApp("Firefox", "org.mozilla.firefox", "org.mozilla.plugincontainer"),
        CallApp("Vivaldi", "com.vivaldi.Vivaldi"),
        CallApp("Opera", "com.operasoftware.Opera"),
        CallApp("Chromium", "org.chromium.Chromium"),
        CallApp("Safari", "com.apple.Safari", "com.apple.WebKit"),
    ]

    /// The Call app a process belongs to: its bundle ID, or a dotted child of it, ignoring case.
    public static func of(_ bundleID: String) -> CallApp? {
        let id = bundleID.lowercased()
        return known.first { app in
            app.bundleIDs.contains { let known = $0.lowercased(); return id == known || id.hasPrefix(known + ".") }
        }
    }

    public static func named(_ id: String) -> CallApp? { known.first { $0.id == id } }
}

/// One process using audio right now, as Core Audio reports it.
public struct AudioClient: Sendable, Equatable {
    public var bundleID: String
    public var input: Bool
    public var output: Bool

    public init(bundleID: String, input: Bool, output: Bool) {
        self.bundleID = bundleID
        self.input = input
        self.output = output
    }
}

public enum CallEvent: Sendable, Equatable {
    case started(CallApp)
    case ended(CallApp)
}

/// Turns snapshots of the audio clients into Call started/ended events.
///
/// A Call starts when one Call app records from the mic for `confirmAfter` seconds while it also plays audio or a
/// camera is on: a voice note, a dictation into a web page, or a video playing in a browser next to a dictation app
/// is not a Call. The camera only backs up an app that already holds the mic (macOS can't say who has the camera),
/// so a camera alone never prompts. It ends when that app has left the mic alone for `endAfter` seconds, so a device switch or a breakout
/// room doesn't split one Call into two.
public struct CallDetector: Sendable {
    public var confirmAfter: TimeInterval = 5
    public var endAfter: TimeInterval = 20
    private var candidates: [CallApp: Date] = [:]
    private var calls: [CallApp: Date] = [:] // → last time the app held the mic

    public init() {}

    /// True while a Call is in progress or about to be confirmed, so the caller keeps sampling.
    public var isTracking: Bool { !candidates.isEmpty || !calls.isEmpty }
    public var current: [CallApp] { calls.keys.sorted { $0.id < $1.id } }

    public mutating func update(_ clients: [AudioClient], cameraOn: Bool = false, at now: Date) -> [CallEvent] {
        var input = Set<CallApp>(), output = Set<CallApp>()
        for client in clients {
            guard let app = CallApp.of(client.bundleID) else { continue }
            if client.input { input.insert(app) }
            if client.output { output.insert(app) }
        }
        var events: [CallEvent] = []
        for (app, lastInput) in calls {
            if input.contains(app) { calls[app] = now } else if now.timeIntervalSince(lastInput) >= endAfter {
                calls[app] = nil
                events.append(.ended(app))
            }
        }
        let onACall = cameraOn ? input : input.intersection(output)
        for app in Array(candidates.keys) where !onACall.contains(app) { candidates[app] = nil }
        for app in onACall where calls[app] == nil {
            let since = candidates[app] ?? now
            if now.timeIntervalSince(since) >= confirmAfter {
                candidates[app] = nil
                calls[app] = now
                events.append(.started(app))
            } else {
                candidates[app] = since
            }
        }
        // Endings first, then starts, each by app, so a tick's events read the same every time.
        return events.sorted { a, b in
            switch (a, b) {
            case let (.ended(x), .ended(y)), let (.started(x), .started(y)): x.id < y.id
            case (.ended, .started): true
            case (.started, .ended): false
            }
        }
    }
}
