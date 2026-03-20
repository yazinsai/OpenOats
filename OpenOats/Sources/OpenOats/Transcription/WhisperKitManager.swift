import Foundation
import WhisperKit
import os

/// Wraps WhisperKit for use as a transcription backend.
/// Handles model download, initialization, and transcription of Float32 audio samples.
final class WhisperKitManager: @unchecked Sendable {
    /// Which Whisper model variant to use.
    enum Variant: String, Sendable {
        case base = "base"
        case small = "small"
        case largeV3 = "large-v3"
        case largeV3Turbo = "large-v3-turbo"

        /// HuggingFace repo hosting the CoreML models.
        static let modelRepo = "argmaxinc/whisperkit-coreml"

        /// Human-readable size for download prompts.
        var downloadSize: String {
            switch self {
            case .base: "~142 MB"
            case .small: "~244 MB"
            case .largeV3: "~3.1 GB"
            case .largeV3Turbo: "~1.6 GB"
            }
        }
    }

    private let variant: Variant
    private let customVocabulary: String
    private var pipe: WhisperKit?
    private var promptTokens: [Int]?
    private let log = Logger(subsystem: "com.openoats", category: "WhisperKitManager")

    init(variant: Variant, customVocabulary: String = "") {
        self.variant = variant
        self.customVocabulary = customVocabulary
    }

    /// Download and initialize the WhisperKit pipeline.
    func setup(progressCallback: ((Progress) -> Void)? = nil) async throws {
        let compute: ModelComputeOptions?
        switch variant {
        case .largeV3, .largeV3Turbo:
            compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuAndNeuralEngine
            )
        case .base, .small:
            compute = nil
        }

        let config = WhisperKitConfig(
            model: variant.rawValue,
            modelRepo: Variant.modelRepo,
            computeOptions: compute,
            verbose: false,
            prewarm: true
        )
        let whisperKit = try await WhisperKit(config)
        self.pipe = whisperKit

        // Tokenize custom vocabulary for prompt conditioning
        let vocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty, let tokenizer = whisperKit.tokenizer {
            let terms = vocab
                .split(separator: "\n")
                .map { line -> String in
                    let preferred = line.split(separator: ":").first ?? line
                    return String(preferred).trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty }
            let promptText = terms.joined(separator: ", ")
            self.promptTokens = tokenizer.encode(text: " " + promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
    }

    /// Transcribe a segment of 16kHz mono Float32 audio samples.
    /// Returns the transcribed text (empty string if nothing recognized).
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else {
            throw WhisperKitManagerError.notInitialized
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            usePrefillCache: promptTokens == nil,
            detectLanguage: true,
            wordTimestamps: false,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check whether the model files already exist locally.
    static func modelExists(variant: Variant) -> Bool {
        let fm = FileManager.default
        // WhisperKit downloads models into ~/Library/Caches/huggingface/models/argmaxinc/whisperkit-coreml/
        // and then into a subfolder matching the variant. We check if any compiled model
        // folder exists. A simpler heuristic: check the default download location.
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let cachesDir else { return false }

        // WhisperKit stores models under:
        // ~/Library/Caches/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-{variant}
        let hfCacheDir = cachesDir
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")

        guard fm.fileExists(atPath: hfCacheDir.path) else { return false }

        // Look for a directory containing the variant name
        guard let contents = try? fm.contentsOfDirectory(atPath: hfCacheDir.path) else {
            return false
        }
        switch variant {
        case .largeV3:
            return contents.contains { $0.contains("whisper-large-v3") && !$0.contains("turbo") }
        case .largeV3Turbo:
            return contents.contains { $0.contains("whisper-large-v3") && $0.contains("turbo") }
        case .base, .small:
            return contents.contains { $0.contains("whisper-\(variant.rawValue)") }
        }
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
