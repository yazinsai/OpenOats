import Foundation

/// A backend config resolved against its Preset, with its API key: what a backend type is built from.
public struct BackendSetup<Kind: Sendable>: Sendable {
    public var type: Kind
    public var address: String?
    public var model: String?
    public var apiKey: String?
    /// Assumed context size: small for local servers, large for cloud APIs.
    public var contextTokens: Int

    public init(type: Kind, address: String?, model: String?, apiKey: String?, contextTokens: Int) {
        self.type = type
        self.address = address
        self.model = model
        self.apiKey = apiKey
        self.contextTokens = contextTokens
    }

    /// Cloud APIs 128k. A local server's context is unknown, so 4096, except Ollama, which is sent `num_ctx` 8192.
    static func contextTokens(_ address: String?) -> Int {
        guard isLocal(address) else { return 128_000 }
        return address.flatMap(URLComponents.init(string:))?.port == 11434 ? 8_192 : 4_096
    }

    static func isLocal(_ address: String?) -> Bool {
        guard let host = address.flatMap(URL.init(string:))?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "0.0.0.0" || host.hasSuffix(".local")
            || ["127.", "10.", "192.168."].contains { host.hasPrefix($0) }
    }
}

/// How each backend type is built. Each backend ticket adds one line to `builtIn`, e.g.
/// `.openAICompatible: { OpenAICompatibleNotes($0) },`. Types without a line build an `UnavailableBackend`.
public struct BackendMakers: Sendable {
    public var transcription: [TranscriptionBackendType: @Sendable (BackendSetup<TranscriptionBackendType>) -> any TranscriptionBackend]
    public var notes: [NotesBackendType: @Sendable (BackendSetup<NotesBackendType>) -> any NotesBackend]

    public init(transcription: [TranscriptionBackendType: @Sendable (BackendSetup<TranscriptionBackendType>) -> any TranscriptionBackend] = [:],
                notes: [NotesBackendType: @Sendable (BackendSetup<NotesBackendType>) -> any NotesBackend] = [:]) {
        self.transcription = transcription
        self.notes = notes
    }

    public static let builtIn = BackendMakers(
        transcription: [
            .openAIStyle: { OpenAIStyleTranscription($0) },
            .elevenLabs: { ElevenLabsTranscription($0) },
            .assemblyAI: { AssemblyAITranscription($0) },
            .gemini: { GeminiTranscription($0) },
        ],
        notes: [
            .openAICompatible: { OpenAICompatibleNotes($0) },
            .anthropic: { AnthropicNotes($0) },
            .gemini: { GeminiNotes($0) },
        ]
    )
}

/// Stands in for a backend type this build doesn't have; fails when used, so Processing shows Needs attention.
struct UnavailableBackend: TranscriptionBackend, NotesBackend {
    var name: String
    var contextTokens: Int { 0 }
    var error: Error { NSError(domain: "OpenOats", code: 1, userInfo: [NSLocalizedDescriptionKey: "The \(name) backend isn't available in this build."]) }
    func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] { throw error }
    func complete(system: String, user: String) async throws -> String { throw error }
}
