import SwiftUI
import OpenOatsKit

// Run `OpenOatsRootApp` as the app itself. Wrapping it in a second `App` whose
// body returned `OpenOatsRootApp().body` built a fresh root (and a fresh app
// delegate) on every scene update, which drops the menu bar item on newer SDKs.
@main
enum OpenOatsMain {
    static func main() {
        OpenOatsRootApp.main()
    }
}
