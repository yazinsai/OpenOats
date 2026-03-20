import Foundation

/// Transcription backend for WhisperKit models.
/// @unchecked Sendable: whisperManager is written once in prepare() before any transcribe() calls.
final class WhisperKitBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let variant: WhisperKitManager.Variant
    private let customVocabulary: String
    private var whisperManager: WhisperKitManager?

    init(variant: WhisperKitManager.Variant, customVocabulary: String = "") {
        self.variant = variant
        self.customVocabulary = customVocabulary
        self.displayName = switch variant {
            case .base: "Whisper Base"
            case .small: "Whisper Small"
            case .largeV3: "Whisper Large v3"
            case .largeV3Turbo: "Whisper Large v3 Turbo"
        }
    }

    func checkStatus() -> BackendStatus {
        let exists = WhisperKitManager.modelExists(variant: variant)
        return exists ? .ready : .needsDownload(
            prompt: "\(displayName) requires a one-time model download (\(variant.downloadSize))."
        )
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let manager = WhisperKitManager(variant: variant, customVocabulary: customVocabulary)
        try await manager.setup()
        self.whisperManager = manager
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let whisperManager else {
            throw TranscriptionBackendError.notPrepared
        }
        return try await whisperManager.transcribe(samples)
    }
}
