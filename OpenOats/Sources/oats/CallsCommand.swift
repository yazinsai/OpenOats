import Foundation
import OatsCapture
import OatsCore

/// `oats calls`: what meeting detection sees, for tuning and bug reports. Prints each change in which processes use
/// the mic (in) and speakers (out), the Call app each belongs to, whether a camera is on, and the Calls the app would ask about. Runs until ^C.
func callsCommand() -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    print("Watching audio clients and Calls. ^C to stop.")
    let watcher = CallWatcher { event in
        switch event {
        case let .started(app): print("\(stamp()) Call started: \(app.name) — the app would ask to record it")
        case let .ended(app): print("\(stamp()) Call ended: \(app.name)")
        }
    }
    watcher.start()
    nonisolated(unsafe) var last: [String] = [] // only the main-run-loop timer touches it
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        let lines = CallWatcher.audioClients().map { client in
            let streams = [client.input ? "in" : nil, client.output ? "out" : nil].compactMap(\.self).joined(separator: "+")
            let app = CallApp.of(client.bundleID).map { "→ \($0.name)" } ?? "(not a Call app)"
            return "  \(client.bundleID.isEmpty ? "<no bundle ID>" : client.bundleID) \(streams) \(app)"
        }.sorted() + (CallWatcher.cameraOn() ? ["  a camera is on"] : [])
        guard lines != last else { return }
        last = lines
        print("\(stamp()) audio clients:\n\(lines.isEmpty ? "  none" : lines.joined(separator: "\n"))")
    }
    RunLoop.main.run()
    exit(0)
}

private func stamp() -> String { Date().formatted(date: .omitted, time: .standard) }
