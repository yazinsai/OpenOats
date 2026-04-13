import Foundation

/// Transcription backend for WhisperKit models (base and small variants).
/// @unchecked Sendable: whisperManager is written once in prepare() before any transcribe() calls.
final class WhisperKitBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName: String
    private let variant: WhisperKitManager.Variant
    private var whisperManager: WhisperKitManager?

    init(variant: WhisperKitManager.Variant) {
        self.variant = variant
        switch variant {
        case .base: self.displayName = "Whisper Base"
        case .small: self.displayName = "Whisper Small"
        case .largeV3Turbo: self.displayName = "Whisper Large v3 Turbo"
        }
    }

    func checkStatus() -> BackendStatus {
        let exists = WhisperKitManager.modelExists(variant: variant)
        return exists ? .ready : .needsDownload(
            prompt: "\(displayName) requires a one-time model download (\(variant.downloadSize))."
        )
    }

    func clearModelCache() {
        let fm = FileManager.default
        guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let hfCacheDir = documentsDir
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
        guard let contents = try? fm.contentsOfDirectory(atPath: hfCacheDir.path) else { return }
        for entry in contents where entry.contains("whisper-\(variant.rawValue)") {
            try? fm.removeItem(at: hfCacheDir.appendingPathComponent(entry))
        }
    }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus("Downloading \(displayName)...")
        let manager = WhisperKitManager(variant: variant)
        try await manager.setup { fraction in
            onProgress(fraction)
        }
        self.whisperManager = manager
    }

    func transcribe(_ samples: [Float], locale: Locale, previousContext: String? = nil) async throws -> String {
        guard let whisperManager else {
            throw TranscriptionBackendError.notPrepared
        }
        return try await whisperManager.transcribe(samples, locale: locale, previousContext: previousContext)
    }
}
