import FluidAudio
import Foundation

/// Transcription backend for Qwen3 ASR 0.6B (30 languages, explicit language hints).
/// @unchecked Sendable: qwen3Manager is written once in prepare() before any transcribe() calls.
final class Qwen3Backend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Qwen3 ASR 0.6B"
    private var qwen3Manager: Qwen3AsrManager?

    func checkStatus() -> BackendStatus {
        let exists = Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
        return exists ? .ready : .needsDownload(prompt: "Qwen3 ASR requires a one-time model download.")
    }

    func clearModelCache() {
        let cacheDir = Qwen3AsrModels.defaultCacheDirectory()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let modelsDirectory = try await Qwen3AsrModels.download()
        onStatus("Initializing \(displayName)...")
        let qwen3 = Qwen3AsrManager()
        try await qwen3.loadModels(from: modelsDirectory)
        self.qwen3Manager = qwen3
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let qwen3Manager else {
            throw TranscriptionBackendError.notPrepared
        }
        let language = Self.qwen3Language(for: locale)
        return try await qwen3Manager.transcribe(
            audioSamples: samples,
            language: language,
            maxNewTokens: 512
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func qwen3Language(for locale: Locale) -> Qwen3AsrConfig.Language? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let languageCode = identifier.split(separator: "-").first.map(String.init)
        guard let languageCode else { return nil }
        return Qwen3AsrConfig.Language(from: languageCode)
    }
}
