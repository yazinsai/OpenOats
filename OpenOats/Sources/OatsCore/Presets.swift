import Foundation

/// A named starting configuration for a backend: fills in its address and default model.
public struct Preset<Kind: Codable & Sendable & Hashable>: Sendable, Hashable {
    public var name: String
    public var type: Kind
    public var address: String
    /// nil = whatever model the server has loaded.
    public var model: String?
    public var needsKey: Bool

    public var config: BackendConfig<Kind> { BackendConfig(type: type, address: address, model: model, preset: name) }
}

extension Preset where Kind == NotesBackendType {
    public static let all: [Preset] = [
        Preset(name: "OpenAI", type: .openAICompatible, address: "https://api.openai.com/v1", model: "gpt-4.1-mini", needsKey: true),
        Preset(name: "OpenRouter", type: .openAICompatible, address: "https://openrouter.ai/api/v1",
               model: "google/gemini-3-flash-preview", needsKey: true),
        Preset(name: "Requesty", type: .openAICompatible, address: "https://router.requesty.ai/v1", model: "openai/gpt-4o-mini", needsKey: true),
        Preset(name: "Anthropic", type: .anthropic, address: "https://api.anthropic.com", model: "claude-sonnet-4-5", needsKey: true),
        Preset(name: "Gemini", type: .gemini, address: "https://generativelanguage.googleapis.com/v1beta",
               model: "gemini-3-flash-preview", needsKey: true),
        Preset(name: "Ollama", type: .openAICompatible, address: "http://localhost:11434/v1", model: "qwen3:8b", needsKey: false),
        Preset(name: "LM Studio", type: .openAICompatible, address: "http://localhost:1234/v1", model: nil, needsKey: false),
        Preset(name: "MLX", type: .openAICompatible, address: "http://localhost:8080/v1",
               model: "mlx-community/Llama-3.2-3B-Instruct-4bit", needsKey: false),
        Preset(name: "llama.cpp", type: .openAICompatible, address: "http://localhost:8080/v1", model: nil, needsKey: false),
    ]
}

extension Preset where Kind == TranscriptionBackendType {
    public static let all: [Preset] = [
        Preset(name: "OpenAI", type: .openAIStyle, address: "https://api.openai.com/v1", model: "whisper-1", needsKey: true),
        Preset(name: "Groq", type: .openAIStyle, address: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", needsKey: true),
        Preset(name: "Self-hosted Whisper", type: .openAIStyle, address: "http://localhost:8000/v1", model: "whisper-1", needsKey: false),
    ]
}
