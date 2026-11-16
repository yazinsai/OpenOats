import Foundation

public enum NotesBackendError: LocalizedError, Equatable {
    case badAddress(String)
    case http(server: String, status: Int, detail: String)
    case badResponse(server: String)
    case noText(server: String, reasoningOnly: Bool)

    public var errorDescription: String? {
        switch self {
        case .badAddress(let address): "\"\(address)\" isn't an http(s) address."
        case .http(let server, let status, let detail):
            "\(server) API error (HTTP \(status)): \(detail)" + ([401, 403].contains(status) ? " Check the API key in Settings > AI." : "")
        case .badResponse(let server): "\(server) returned a response OpenOats couldn't read."
        case .noText(let server, let reasoningOnly):
            "\(server) returned no text" + (reasoningOnly ? ", only reasoning. Turn off thinking mode on the server." : ".")
        }
    }
}

/// The OpenAI-compatible Notes backend: `POST …/chat/completions` (OpenAI, OpenRouter, Requesty, LM Studio, MLX, llama.cpp, custom).
/// Ollama (port 11434) gets its native `/api/chat`, the only way to set its context size: `/v1` silently cuts prompts at its default.
public struct OpenAICompatibleNotes: NotesBackend {
    public var address: String
    public var model: String?
    public var apiKey: String?
    public var contextTokens: Int
    public var session: URLSession
    public var attempts = 3
    public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public var name: String { "openai-compatible:\(model ?? URL(string: address)?.host() ?? address)" }

    public init(_ setup: BackendSetup<NotesBackendType>, session: URLSession = URLSession(configuration: .ephemeral)) {
        address = setup.address ?? ""
        model = setup.model
        apiKey = setup.apiKey?.isEmpty == false ? setup.apiKey : nil
        contextTokens = setup.contextTokens
        self.session = session
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
        guard let (url, ollama) = endpoint else { throw NotesBackendError.badAddress(address) }
        let server = ollama ? "Ollama" : url.host() ?? address
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

        let json = try await send(request, server: server)
        let choice = (json["choices"] as? [[String: Any]])?.first
        guard let message = (ollama ? json["message"] : choice?["message"]) as? [String: Any] else {
            throw NotesBackendError.badResponse(server: server)
        }
        var text = message["content"] as? String ?? ""
        if let end = text.range(of: "</think>"), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            text = String(text[end.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let reasoning = ["reasoning", "reasoning_content", "thinking"].contains { (message[$0] as? String)?.isEmpty == false }
            throw NotesBackendError.noText(server: server, reasoningOnly: reasoning)
        }
        return text
    }

    /// Retries 429, 5xx and dropped connections with exponential backoff (or the server's `Retry-After`).
    private func send(_ request: URLRequest, server: String) async throws -> [String: Any] {
        var delay = Duration.seconds(2)
        for attempt in 1... {
            let last = attempt >= attempts
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if (200..<300).contains(status) {
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw NotesBackendError.badResponse(server: server)
                    }
                    return json
                }
                guard status == 429 || status >= 500, !last else {
                    throw NotesBackendError.http(server: server, status: status, detail: Self.detail(data))
                }
                if let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) { delay = .seconds(min(after, 30)) }
            } catch let error as URLError where !last && [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {}
            try await sleep(delay)
            delay *= 2
        }
        fatalError("unreachable")
    }

    /// The server's own error text (Ollama's names the missing model), on one line.
    static func detail(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["message"] as? String
            ?? json?["message"] as? String ?? String(decoding: data, as: UTF8.self)
        return String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
    }
}

extension NotesBackend {
    /// The settings Test button: one tiny request that proves the address, key and model work.
    public func test() async throws {
        _ = try await complete(system: "Reply with the single word OK.", user: "Test")
    }
}
