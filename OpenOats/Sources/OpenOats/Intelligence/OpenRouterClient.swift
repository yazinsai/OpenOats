import Foundation

/// Streaming OpenAI-compatible client for OpenRouter API (and Ollama via OpenAI-compatible endpoint).
actor OpenRouterClient {
    private static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Builds a chat completions URL from a user-provided base URL, stripping
    /// any trailing `/v1` or `/v1/chat/completions` to avoid double-pathing.
    static func chatCompletionsURL(from rawBase: String) -> URL? {
        var base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Strip paths that users commonly include so we don't get /v1/v1/...
        for suffix in ["/v1/chat/completions", "/v1"] {
            if base.hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
            }
        }
        return URL(string: base + "/v1/chat/completions")
    }

    static func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    struct WebSearchPlugin: Codable, Sendable {
        let id: String
        let max_results: Int

        static let `default` = WebSearchPlugin(id: "web", max_results: 5)
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let max_tokens: Int?
        let max_completion_tokens: Int?
        let temperature: Double?
        let plugins: [WebSearchPlugin]?
    }

    /// Whether a URL points to a host that supports the `max_completion_tokens`
    /// parameter (OpenAI, OpenRouter). Other OpenAI-compatible providers such as
    /// Mistral and Ollama only accept `max_tokens`.
    private static func usesMaxCompletionTokens(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host.contains("openrouter.ai") || host.contains("openai.com")
    }

    /// Streams the completion response, yielding text chunks.
    func streamCompletion(
        apiKey: String? = nil,
        model: String,
        messages: [Message],
        maxTokens: Int = 1024,
        baseURL: URL? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let targetURL = baseURL ?? Self.defaultBaseURL
                    let useNewParam = Self.usesMaxCompletionTokens(targetURL)
                    let request = ChatRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        max_tokens: useNewParam ? nil : maxTokens,
                        max_completion_tokens: useNewParam ? maxTokens : nil,
                        temperature: nil,
                        plugins: nil
                    )

                    var urlRequest = URLRequest(url: targetURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey, !apiKey.isEmpty {
                        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    if targetURL.host?.contains("openrouter.ai") == true {
                        urlRequest.setValue("OpenOats/2.0", forHTTPHeaderField: "HTTP-Referer")
                    }
                    urlRequest.httpBody = try JSONEncoder().encode(request)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.finish(throwing: OpenRouterError.httpError(statusCode, host: targetURL.host))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data),
                           let content = chunk.choices.first?.delta.content {
                            continuation.yield(content)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Non-streaming completion for structured JSON tasks (gate decisions, state updates).
    func complete(
        apiKey: String? = nil,
        model: String,
        messages: [Message],
        maxTokens: Int = 512,
        temperature: Double? = nil,
        baseURL: URL? = nil,
        webSearch: Bool = false
    ) async throws -> String {
        let targetURL = baseURL ?? Self.defaultBaseURL
        let useNewParam = Self.usesMaxCompletionTokens(targetURL)
        let request = ChatRequest(
            model: model,
            messages: messages,
            stream: false,
            max_tokens: useNewParam ? nil : maxTokens,
            max_completion_tokens: useNewParam ? maxTokens : nil,
            temperature: temperature,
            plugins: webSearch ? [.default] : nil
        )
        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if targetURL.host?.contains("openrouter.ai") == true {
            urlRequest.setValue("OpenOats/2.0", forHTTPHeaderField: "HTTP-Referer")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenRouterError.httpError(statusCode, host: targetURL.host)
        }

        let completionResponse = try JSONDecoder().decode(CompletionResponse.self, from: data)
        return completionResponse.choices.first?.message.content ?? ""
    }

    enum OpenRouterError: Error, LocalizedError {
        case httpError(Int, host: String?)

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let host):
                let provider = switch host {
                case let h? where h.contains("openrouter.ai"): "OpenRouter"
                case let h? where h.contains("localhost"), let h? where h.contains("127.0.0.1"): "Local LLM"
                case let h?: h
                case nil: "LLM"
                }
                return "\(provider) API error (HTTP \(code))"
            }
        }
    }

    // MARK: - SSE Types

    private struct SSEChunk: Codable {
        let choices: [Choice]

        struct Choice: Codable {
            let delta: Delta
        }

        struct Delta: Codable {
            let content: String?
        }
    }

    private struct CompletionResponse: Codable {
        let choices: [CompletionChoice]

        struct CompletionChoice: Codable {
            let message: CompletionMessage
        }

        struct CompletionMessage: Codable {
            let content: String
        }
    }
}
