import AVFoundation
import Foundation

enum StreamingTranscriptionError: Error, LocalizedError, Sendable {
    case unsupportedOnThisOS
    case unsupportedLocale(String)
    case notPrepared
    case assetInstallFailed(String)
    case sessionContention(String)
    case analyzerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOnThisOS:
            "Apple SpeechAnalyzer requires macOS 26 or later."
        case .unsupportedLocale(let locale):
            "SpeechAnalyzer does not support locale \"\(locale)\". Choose a supported locale in Settings or switch to Parakeet."
        case .notPrepared:
            "SpeechAnalyzer is not prepared yet. Wait for model download to finish or try again."
        case .assetInstallFailed(let detail):
            "Failed to install Apple speech assets: \(detail)"
        case .sessionContention(let detail):
            "SpeechAnalyzer is busy: \(detail). Stop other recordings using speech recognition and try again."
        case .analyzerFailed(let detail):
            "SpeechAnalyzer failed: \(detail)"
        }
    }
}

protocol StreamingTranscriptionProvider: Sendable {
    var displayName: String { get }
    func checkStatus(locale: Locale) async -> BackendStatus
    func prepare(
        locale: Locale,
        onStatus: @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// One independent live session per speaker stream (you / them).
    func makeSession(locale: Locale) async throws -> any StreamingTranscriptionSession
}

protocol StreamingTranscriptionSession: Sendable {
    func run(
        stream: AsyncStream<AVAudioPCMBuffer>,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (StreamingTranscriber.FinalSegment) -> Void
    ) async
    func finish() async
}
