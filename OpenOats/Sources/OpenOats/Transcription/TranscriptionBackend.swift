import Foundation

/// Status of a transcription backend's readiness.
enum BackendStatus: Equatable, Sendable {
    case ready
    case needsDownload(prompt: String)
}

/// Unified interface for all transcription backends (local and cloud).
/// Each backend handles its own model lifecycle and transcription logic.
///
/// Conforming types receive raw audio samples. This protocol is internal
/// and backends are instantiated only via TranscriptionModel.makeBackend().
protocol TranscriptionBackend: Sendable {
    /// Human-readable name for UI display.
    var displayName: String { get }

    /// Check whether this backend is ready to transcribe.
    func checkStatus() -> BackendStatus

    /// Prepare the backend for use (download models, validate API keys, etc.).
    /// Must be called exactly once, and must complete before any call to transcribe().
    func prepare(onStatus: @Sendable (String) -> Void) async throws

    /// Transcribe a segment of Float32 audio samples at 16kHz mono.
    /// Returns the transcribed text, or empty string if no speech detected.
    /// - Parameters:
    ///   - samples: Float32 audio at 16kHz mono.
    ///   - locale: Language hint.
    ///   - previousContext: Trailing words from the prior segment, used to prime the decoder
    ///     for cross-segment continuity. Backends that don't support prompting ignore this.
    func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String

    /// Remove cached model files so the next prepare() triggers a fresh download.
    func clearModelCache()
}

extension TranscriptionBackend {
    func clearModelCache() {}
}

enum TranscriptionBackendError: Error {
    case notPrepared
}
