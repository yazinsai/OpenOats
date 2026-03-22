import Foundation

enum UITestScenario: String {
    case launchSmoke
    case sessionSmoke
    case notesSmoke
}

enum AppRuntimeMode {
    case live
    case uiTest(UITestScenario)
}
