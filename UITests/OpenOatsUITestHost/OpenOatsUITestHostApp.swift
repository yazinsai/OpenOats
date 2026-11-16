import SwiftUI

/// XCUITest needs a target app; the smoke suite drives the packaged OpenOats.app instead (see scripts/run_ui_smoke.sh).
@main
struct OpenOatsUITestHostApp: App {
    var body: some Scene { WindowGroup { Text("OpenOats UI test host") } }
}
