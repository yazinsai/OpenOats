import FluidAudio
import Foundation

/// Transcription backend for Qwen3 ASR 0.6B (30 languages, explicit language hints).
/// @unchecked Sendable: qwen3Manager is written once in prepare() before any transcribe() calls.
final class Qwen3Backend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Qwen3 ASR 0.6B"
    private let variant: Qwen3AsrVariant
    private var qwen3Manager: Qwen3AsrManager?

    init(variant: Qwen3AsrVariant = .f32) {
        self.variant = variant
    }

    func checkStatus() -> BackendStatus {
        let exists = Qwen3AsrModels.modelsExist(
            at: OpenOatsLocalModelStore.qwen3Directory(variant: variant)
        )
        return exists ? .ready : .needsDownload(prompt: "Qwen3 ASR requires a one-time model download.")
    }

    func clearModelCache() {
        OpenOatsLocalModelStore.clearQwen3Cache(variant: variant)
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let modelsDirectory = OpenOatsLocalModelStore.qwen3Directory(variant: variant)

        if Qwen3AsrModels.modelsExist(at: modelsDirectory) {
            onStatus("Initializing \(displayName)...")
        } else {
            onStatus("Downloading \(displayName)...")
            let downloadedDirectory = try await Qwen3AsrModels.download(variant: variant, progressHandler: { progress in
                onProgress(progress.fractionCompleted)
            })
            _ = OpenOatsLocalModelStore.migrateDownloadedQwen3Models(
                from: downloadedDirectory,
                variant: variant
            )
            onStatus("Initializing \(displayName)...")
        }

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
