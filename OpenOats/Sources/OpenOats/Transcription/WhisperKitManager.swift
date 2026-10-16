import Foundation
import WhisperKit

/// Wraps WhisperKit for use as a transcription backend.
/// Handles model download, initialization, and transcription of Float32 audio samples.
final class WhisperKitManager: @unchecked Sendable {
    /// Which Whisper model variant to use.
    enum Variant: String, Sendable {
        case base = "base"
        case small = "small"
        case largeV3Turbo = "large-v3-v20240930"

        /// HuggingFace repo hosting the CoreML models.
        static let modelRepo = "argmaxinc/whisperkit-coreml"

        /// Human-readable size for download prompts.
        var downloadSize: String {
            switch self {
            case .base: "~142 MB"
            case .small: "~244 MB"
            case .largeV3Turbo: "~800 MB"
            }
        }
    }

    private let variant: Variant
    private var pipe: WhisperKit?

    init(variant: Variant) {
        self.variant = variant
    }

    /// Download and initialize the WhisperKit pipeline.
    /// - Parameter progressCallback: Optional callback reporting download progress (0…1).
    func setup(progressCallback: ((Double) -> Void)? = nil) async throws {
        // Download with progress reporting, then load from the local folder.
        let modelFolder = try await WhisperKit.download(
            variant: variant.rawValue,
            from: Variant.modelRepo,
            endpoint: ModelHubEndpoint.current
        ) { progress in
            progressCallback?(progress.fractionCompleted)
        }

        let config = WhisperKitConfig(
            model: variant.rawValue,
            modelRepo: Variant.modelRepo,
            modelEndpoint: ModelHubEndpoint.current,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        self.pipe = whisperKit
    }

    /// Transcribe a segment of 16kHz mono Float32 audio samples.
    /// Returns the transcribed text (empty string if nothing recognized).
    /// - Parameter previousContext: Ignored. Passing prior words as Whisper prompt
    ///   tokens makes WhisperKit return empty text for every segment, so after the
    ///   first sentence of a meeting nothing more was transcribed.
    func transcribe(_ samples: [Float], locale: Locale? = nil, previousContext: String? = nil) async throws -> String {
        guard let pipe else {
            throw WhisperKitManagerError.notInitialized
        }
        // Extract 2-letter language code (e.g. "he", "en") from locale.
        // When nil, Whisper auto-detects — but auto-detect often outputs
        // Latin transliteration for non-Latin scripts like Hebrew/Arabic.
        let languageCode = locale?.language.languageCode?.identifier

        let options = DecodingOptions(
            language: languageCode,
            wordTimestamps: false
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check whether the model files already exist locally.
    static func modelExists(variant: Variant) -> Bool {
        let fm = FileManager.default
        let subpath = ["huggingface", "models", "argmaxinc", "whisperkit-coreml"]

        // WhisperKit's Hub client downloads models into ~/Documents/huggingface/…
        // Earlier versions used ~/Library/Caches/huggingface/… — check both for
        // backward compatibility.
        let roots: [URL?] = [
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ]

        for root in roots.compactMap({ $0 }) {
            var dir = root
            for component in subpath { dir.appendPathComponent(component) }

            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if contents.contains(where: { $0.contains("whisper-\(variant.rawValue)") }) {
                return true
            }
        }
        return false
    }

    enum WhisperKitManagerError: LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                "WhisperKit pipeline is not initialized. Call setup() first."
            }
        }
    }
}
