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

struct AppServices {
    let knowledgeBase: KnowledgeBase
    let suggestionEngine: SuggestionEngine
    let sidecastEngine: SidecastEngine
    let transcriptionEngine: TranscriptionEngine
    let liveTranscriptCleaner: LiveTranscriptCleaner
    let audioRecorder: AudioRecorder
    let batchAudioTranscriber: BatchAudioTranscriber
}

struct AppLaunchContext {
    let isFirstLaunch: Bool
    let uiTestScenario: UITestScenario?
    let runtimeMode: AppRuntimeMode
    let container: AppContainer
    let settings: AppSettings
    let coordinator: AppCoordinator
    let updaterController: AppUpdaterController
}
