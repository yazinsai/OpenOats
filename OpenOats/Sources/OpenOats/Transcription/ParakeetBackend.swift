import FluidAudio
import Foundation

/// Transcription backend for Parakeet-TDT models (v2 English-only, v3 multilingual).
/// @unchecked Sendable: asrManager is written once in prepare() before any transcribe() calls.
final class ParakeetBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let version: AsrModelVersion
    private let customVocabularyText: String
    private var asrManager: AsrManager?

    init(version: AsrModelVersion, customVocabulary: String = "") {
        self.version = version
        self.customVocabularyText = customVocabulary
        self.displayName = version == .v2 ? "Parakeet TDT v2" : "Parakeet TDT v3"
    }

    func checkStatus() -> BackendStatus {
        let exists = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version),
            version: version
        )
        return exists ? .ready : .needsDownload(prompt: "Transcription requires a one-time model download.")
    }

    func clearModelCache() {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let models = try await AsrModels.downloadAndLoad(version: version)
        onStatus("Initializing \(displayName)...")
        let asr = AsrManager(config: .default)
        try await asr.initialize(models: models)

        // Configure custom vocabulary boosting if provided
        let vocab = customVocabularyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openoats-custom-vocabulary-\(UUID().uuidString).txt")
            try vocab.write(to: tempURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let (customVocabulary, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(
                from: tempURL.path
            )
            if !customVocabulary.terms.isEmpty {
                try await asr.configureVocabularyBoosting(
                    vocabulary: customVocabulary,
                    ctcModels: ctcModels
                )
            }
        }

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
