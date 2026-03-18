import FluidAudio
import Foundation

/// Transcription backend for Parakeet-TDT models (v2 English-only, v3 multilingual).
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let version: AsrModelVersion
    private var asrManager: AsrManager?

    init(version: AsrModelVersion) {
        self.version = version
        self.displayName = version == .v2 ? "Parakeet TDT v2" : "Parakeet TDT v3"
    }

    func checkStatus() -> BackendStatus {
        let exists = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version),
            version: version
        )
        return exists ? .ready : .needsDownload(prompt: "Transcription requires a one-time model download.")
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let models = try await AsrModels.downloadAndLoad(version: version)
        onStatus("Initializing \(displayName)...")
        let asr = AsrManager(config: .default)
        try await asr.initialize(models: models)
        self.asrManager = asr
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let asrManager else {
            throw TranscriptionBackendError.notPrepared
        }
        let result = try await asrManager.transcribe(samples)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
