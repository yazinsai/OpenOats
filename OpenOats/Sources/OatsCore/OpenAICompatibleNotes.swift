import Foundation

/// The OpenAI-compatible Notes backend: `POST …/chat/completions` (OpenAI, OpenRouter, Requesty, LM Studio, MLX, llama.cpp, custom).
/// Ollama (port 11434) gets its native `/api/chat`, the only way to set its context size: `/v1` silently cuts prompts at its default.
public struct OpenAICompatibleNotes: NotesBackend {
    public var address: String
    public var model: String?
    public var apiKey: String?
    public var contextTokens: Int
    public var client: CloudClient

    public var name: String { "openai-compatible:\(model ?? URL(string: address)?.host() ?? address)" }

    public init(_ setup: BackendSetup<NotesBackendType>, session: URLSession = URLSession(configuration: .ephemeral)) {
        address = setup.address ?? ""
        model = setup.model
        apiKey = setup.apiKey?.isEmpty == false ? setup.apiKey : nil
        contextTokens = setup.contextTokens
        client = CloudClient(backend: "", session: session)
    }

    /// Accepts every pasted variant: `host`, `host/v1`, `host/v1/` or the full `…/chat/completions`.
    var endpoint: (url: URL, ollama: Bool)? {
        var s = address.trimmingCharacters(in: .whitespaces)
        guard var parts = URLComponents(string: s), parts.scheme?.hasPrefix("http") == true, parts.host != nil else { return nil }
        if parts.port == 11434 {
            parts.path = "/api/chat"
            return parts.url.map { ($0, true) }
        }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/chat/completions") {
            if s.hasSuffix("/v1") { s.removeLast(3) }
            s += "/v1/chat/completions"
        }
        return URL(string: s).map { ($0, false) }
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let (url, ollama) = endpoint else { throw CloudError.badAddress(address) }
        var client = client
        client.backend = ollama ? "Ollama" : url.host() ?? address
        var body: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": user]], "stream": false]
        if let model { body["model"] = model }
        if ollama { // Notes don't need a thinking model's reasoning; skipping it saves minutes on a laptop
            body["options"] = ["num_ctx": contextTokens]
            body["think"] = false
        }
        var request = URLRequest(url: url, timeoutInterval: 600) // local models can take minutes to load and answer
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if url.host()?.hasSuffix("openrouter.ai") == true {
            request.setValue("https://github.com/yazinsai/OpenOats", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("OpenOats", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try JSONSerialization.jsonObject(with: try await client.send(request)) as? [String: Any]
        let choice = (json?["choices"] as? [[String: Any]])?.first
        guard let message = (ollama ? json?["message"] : choice?["message"]) as? [String: Any] else {
            throw CloudError.badResponse(backend: client.backend)
        }
        var text = message["content"] as? String ?? ""
        if let end = text.range(of: "</think>"), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            text = String(text[end.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.empty } // e.g. a reasoning-only reply
        return text
    }
}

extension NotesBackend {
    /// The settings Test button: one tiny request that proves the address, key and model work.
    public func test() async throws {
        _ = try await complete(system: "Reply with the single word OK.", user: "Test")
    }
}
