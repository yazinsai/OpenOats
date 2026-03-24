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
    private let log = Logger(subsystem: "com.openoats", category: "WhisperKitManager")

    init(variant: Variant) {
        self.variant = variant
    }

    /// Download and initialize the WhisperKit pipeline.
    func setup(progressCallback: ((Progress) -> Void)? = nil) async throws {
        let config = WhisperKitConfig(
            model: variant.rawValue,
            modelRepo: Variant.modelRepo,
            verbose: false,
            prewarm: true
        )
        let whisperKit = try await WhisperKit(config)
        self.pipe = whisperKit
    }

    /// Transcribe a segment of 16kHz mono Float32 audio samples.
    /// Returns the transcribed text (empty string if nothing recognized).
    /// - Parameter previousContext: Trailing words from the prior segment, encoded as prompt
    ///   tokens to prime the Whisper decoder for cross-segment continuity.
    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard let pipe else {
            throw WhisperKitManagerError.notInitialized
        }
        var promptTokens: [Int]?
        if let context = previousContext, !context.isEmpty, let tokenizer = pipe.tokenizer {
            let encoded = tokenizer.encode(text: " " + context).filter {
                $0 < tokenizer.specialTokens.specialTokenBegin
            }
            if !encoded.isEmpty {
                promptTokens = encoded
            }
        }
        let options = DecodingOptions(
            // Let Whisper auto-detect the language
            language: nil,
            wordTimestamps: false,
            promptTokens: promptTokens
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check whether the model files already exist locally.
    static func modelExists(variant: Variant) -> Bool {
        modelFolderURL(variant: variant) != nil
    }

    static func clearModelCache(variant: Variant) {
        let fm = FileManager.default
        for baseDir in hubSearchRoots() {
            let repoDir = repositoryRoot(in: baseDir)
            guard let contents = try? fm.contentsOfDirectory(atPath: repoDir.path) else { continue }
            for entry in contents where entry.contains("whisper-\(variant.rawValue)") {
                try? fm.removeItem(at: repoDir.appendingPathComponent(entry))
            }
        }
    }

    private static func modelFolderURL(variant: Variant) -> URL? {
        let fm = FileManager.default
        for baseDir in hubSearchRoots() {
            let repoDir = repositoryRoot(in: baseDir)
            guard fm.fileExists(atPath: repoDir.path) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: repoDir.path) else {
                continue
            }
            guard let folderName = contents.first(where: { $0.contains("whisper-\(variant.rawValue)") }) else {
                continue
            }
            return repoDir.appendingPathComponent(folderName, isDirectory: true)
        }
        return nil
    }

    private static func hubSearchRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        if let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(documentsDir.appendingPathComponent("huggingface", isDirectory: true))
        }
        if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(cachesDir.appendingPathComponent("huggingface", isDirectory: true))
        }
        return roots
    }

    private static func repositoryRoot(in hubBase: URL) -> URL {
        hubBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
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
