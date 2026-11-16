import Foundation

/// A stretch of speech in one track, in seconds from the start of the track.
public struct TimedSegment: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Speaker label from a backend that separates speakers itself; nil otherwise.
    public var speaker: String?

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// Turns one track's audio file (`.pcm` 16 kHz mono Int16, `.m4a`, or any AVFoundation format) into timed segments.
public protocol TranscriptionBackend: Sendable {
    /// Short engine name written to the Meeting file's `engine` field, e.g. `parakeet-v3`.
    var name: String { get }
    /// True if the backend labels speakers itself (used only for single mixed-file imports).
    var separatesSpeakers: Bool { get }
    /// `language` is a BCP 47 code or nil for the backend's own detection.
    func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment]
    /// Frees loaded models; Processing calls it after the transcribe step.
    func unload() async
}

extension TranscriptionBackend {
    public var separatesSpeakers: Bool { false }
    public func unload() async {}
}

/// A language model that only ever sees text: system + user prompt in, text out.
public protocol NotesBackend: Sendable {
    /// Short name recorded in `meeting.json`, e.g. `openai-compatible:gpt-4.1-mini`.
    var name: String { get }
    /// Approximate context size in tokens, used to decide when to summarise in pieces.
    var contextTokens: Int { get }
    func complete(system: String, user: String) async throws -> String
}

/// The Transcription backend types (ADR 0003).
public enum TranscriptionBackendType: String, Codable, Sendable, CaseIterable {
    case onDevice = "on-device", openAIStyle = "openai-style", elevenLabs = "elevenlabs", assemblyAI = "assemblyai", gemini
}

/// The Notes backend types (ADR 0003).
public enum NotesBackendType: String, Codable, Sendable, CaseIterable {
    case none, openAICompatible = "openai-compatible", anthropic, gemini
}

/// One backend slot's saved configuration. Secrets live in the Keychain, never here.
public struct BackendConfig<Kind: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var type: Kind
    /// Base address, e.g. `http://localhost:11434/v1`; nil means the type's default.
    public var address: String?
    public var model: String?
    /// Name of the Preset this was filled in from, if any.
    public var preset: String?

    public init(type: Kind, address: String? = nil, model: String? = nil, preset: String? = nil) {
        self.type = type
        self.address = address
        self.model = model
        self.preset = preset
    }
}

public typealias TranscriptionConfig = BackendConfig<TranscriptionBackendType>
public typealias NotesConfig = BackendConfig<NotesBackendType>
