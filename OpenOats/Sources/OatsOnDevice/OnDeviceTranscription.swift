import FluidAudio
import Foundation
import OatsCore
import WhisperKit

/// The On-device Transcription backend: Parakeet v3 for its 25 European languages, Whisper large-v3-turbo for the rest.
/// The model loads on the first track of a Meeting and stays until Processing calls `unload()`.
/// @unchecked Sendable: Processing transcribes one track at a time, so the loaded models are never shared.
public final class OnDeviceTranscription: TranscriptionBackend, @unchecked Sendable {
    public enum Model: String, Sendable { case parakeet = "parakeet-tdt-v3", whisper = "whisper-large-v3-turbo" }

    /// Languages Parakeet v3 handles (NVIDIA parakeet-tdt-0.6b-v3 model card).
    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
    ]
    static let whisperVariant = "large-v3-v20240930"
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    public static var defaultModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenOats/Models/Transcription", isDirectory: true)
    }

    public let model: Model
    public var name: String { model.rawValue }
    let language: String
    let modelsRoot: URL
    let progress: (@Sendable (Double) -> Void)?
    private var parakeet: AsrManager?
    private var whisper: WhisperKit?

    /// `language` is the language setting (BCP 47; nil = system language). `progress` reports model download (0…1).
    public init(language: String?, modelsRoot: URL = defaultModelsRoot, progress: (@Sendable (Double) -> Void)? = nil) {
        self.language = Self.languageCode(language)
        model = Self.parakeetLanguages.contains(self.language) ? .parakeet : .whisper
        self.modelsRoot = modelsRoot
        self.progress = progress
    }

    static func languageCode(_ language: String?) -> String {
        let locale = language.map(Locale.init(identifier:)) ?? .current
        return locale.language.languageCode?.identifier ?? "en"
    }

    /// 1.x layout: FluidAudio downloads into the parent of this (never created) `current` folder.
    var parakeetDirectory: URL { modelsRoot.appendingPathComponent("parakeet/parakeet-v3/current") }
    var whisperDirectory: URL {
        modelsRoot.appendingPathComponent("whisper/models/\(Self.whisperRepo)/openai_whisper-\(Self.whisperVariant)")
    }

    public var isDownloaded: Bool {
        switch model {
        case .parakeet: AsrModels.modelsExist(at: parakeetDirectory, version: .v3)
        case .whisper: FileManager.default.fileExists(atPath: whisperDirectory.appendingPathComponent("config.json").path)
        }
    }

    /// Downloads the model if missing, without loading it (onboarding does this in the background).
    public func download() async throws {
        guard !isDownloaded else { return }
        let progress = progress
        switch model {
        case .parakeet:
            try await AsrModels.download(to: parakeetDirectory, version: .v3) { progress?($0.fractionCompleted) }
        case .whisper:
            _ = try await WhisperKit.download(variant: Self.whisperVariant, downloadBase: modelsRoot.appendingPathComponent("whisper"),
                                              from: Self.whisperRepo) { progress?($0.fractionCompleted) }
        }
    }

    public func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        let samples = try TrackAudio.samples(of: audio)
        guard samples.count >= 16_000 else { return [] } // both models reject < 1 s
        try await download()
        switch model {
        case .parakeet:
            if parakeet == nil {
                let asr = AsrManager(config: .default)
                try await asr.loadModels(try await AsrModels.load(from: parakeetDirectory, version: .v3))
                parakeet = asr
            }
            // FluidAudio's own long-audio chunking drops stretches of speech, so feed it single-pass pieces.
            var tokens: [TokenTiming] = []
            for piece in Self.pieces(samples) {
                let audio = Array(samples[piece]) + [Float](repeating: 0, count: max(0, 16_000 - piece.count))
                let offset = Double(piece.lowerBound) / TrackAudio.sampleRate
                tokens += (try await parakeet!.transcribe(audio, source: .system).tokenTimings ?? []).map {
                    TokenTiming(token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime + offset,
                                endTime: $0.endTime + offset, confidence: $0.confidence)
                }
            }
            return Self.segments(tokens)
        case .whisper:
            if whisper == nil {
                whisper = try await WhisperKit(WhisperKitConfig(model: Self.whisperVariant, modelRepo: Self.whisperRepo,
                                                                modelFolder: whisperDirectory.path, verbose: false,
                                                                prewarm: true, download: false))
            }
            // Always pass the language: auto-detect transliterates non-Latin scripts.
            // Word timings give real start times (segment starts snap to the chunk start after silence).
            let options = DecodingOptions(language: Self.languageCode(language ?? self.language),
                                          skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
            let results = try await whisper!.transcribe(audioArray: samples, decodeOptions: options)
            return results.flatMap(\.segments).map {
                TimedSegment(start: Double($0.words?.first?.start ?? $0.start), end: Double($0.words?.last?.end ?? $0.end),
                             text: $0.text.trimmingCharacters(in: .whitespaces))
            }.filter { !$0.text.isEmpty && Self.isAudible($0, in: samples) }
        }
    }

    public func unload() async {
        await parakeet?.cleanup()
        parakeet = nil
        await whisper?.unloadModels()
        whisper = nil
    }

    /// Splits samples into pieces of at most 15 s (Parakeet's single pass), cut in the quietest 0.5 s after 5 s.
    static func pieces(_ samples: [Float]) -> [Range<Int>] {
        let window = 240_000, minimum = 80_000, quiet = 8_000
        var out: [Range<Int>] = [], start = 0
        while samples.count - start > window {
            var cut = start + window, quietest = Float.infinity
            for f in stride(from: start + minimum, through: start + window - quiet, by: 800) {
                let energy = samples[f..<f + quiet].reduce(0) { $0 + $1 * $1 }
                if energy < quietest { (quietest, cut) = (energy, f + quiet / 2) }
            }
            out.append(start..<cut)
            start = cut
        }
        return out + [start..<samples.count]
    }

    /// False for near-silent spans, where Whisper hallucinates ("Thanks for watching").
    static func isAudible(_ segment: TimedSegment, in samples: [Float]) -> Bool {
        let range = max(0, Int(segment.start * 16_000))..<min(samples.count, Int(segment.end * 16_000) + 1)
        return range.count > 0 && stride(from: range.lowerBound, to: range.upperBound, by: 1_600).contains { f in
            let frame = samples[f..<min(f + 1_600, range.upperBound)]
            return (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot() > 0.01
        }
    }

    /// Pause after which a new segment starts even mid-sentence.
    static let segmentGap: TimeInterval = 1.0

    /// Groups Parakeet's tokens (a leading space or `▁` starts a word) into segments, cut after sentence punctuation or a pause.
    static func segments(_ tokens: [TokenTiming]) -> [TimedSegment] {
        var out: [TimedSegment] = []
        var current: TimedSegment?
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if var segment = current {
                let newWord = piece.hasPrefix(" ")
                let sentenceEnd = segment.text.last.map { ".?!".contains($0) } ?? false
                if newWord && (sentenceEnd || token.startTime - segment.end > segmentGap) {
                    out.append(segment)
                    current = TimedSegment(start: token.startTime, end: token.endTime, text: piece)
                    continue
                }
                segment.text += piece
                segment.end = token.endTime
                current = segment
            } else {
                current = TimedSegment(start: token.startTime, end: token.endTime, text: piece)
            }
        }
        if let current { out.append(current) }
        return out.map { TimedSegment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
    }
}
