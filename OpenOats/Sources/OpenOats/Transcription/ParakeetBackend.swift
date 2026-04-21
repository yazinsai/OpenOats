import FluidAudio
import Foundation

/// Transcription backend for Parakeet-TDT models (v2 English-only, v3 multilingual).
/// @unchecked Sendable: asrManager is written once in prepare() before any transcribe() calls.
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let version: AsrModelVersion
    private var asrManager: AsrManager?

    init(version: AsrModelVersion, customVocabulary: String = "") {
        self.version = version
        self.displayName = version == .v2 ? "Parakeet TDT v2" : "Parakeet TDT v3"
    }

    func checkStatus() -> BackendStatus {
        let exists = AsrModels.modelsExist(
            at: OpenOatsLocalModelStore.parakeetDirectory(for: version),
            version: version
        )
        return exists ? .ready : .needsDownload(prompt: "Transcription requires a one-time model download.")
    }

    func clearModelCache() {
        OpenOatsLocalModelStore.clearParakeetCache(for: version)
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let models: AsrModels
        let modelsDirectory = OpenOatsLocalModelStore.parakeetDirectory(for: version)
        if AsrModels.modelsExist(at: modelsDirectory, version: version) {
            onStatus("Initializing \(displayName)...")
            models = try await AsrModels.load(from: modelsDirectory, version: version)
        } else {
            onStatus("Downloading \(displayName)...")
            models = try await AsrModels.downloadAndLoad(to: modelsDirectory, version: version) { progress in
                onProgress(progress.fractionCompleted)
            }
            onStatus("Initializing \(displayName)...")
        }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.asrManager = asr
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let asrManager else {
            throw TranscriptionBackendError.notPrepared
        }
        let result = try await asrManager.transcribe(samples)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
