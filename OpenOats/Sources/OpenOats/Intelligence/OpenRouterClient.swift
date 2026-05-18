import Foundation

/// Streaming OpenAI-compatible client for OpenRouter API (and Ollama via OpenAI-compatible endpoint).
actor OpenRouterClient {
    private static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let anthropicVersion = "2023-06-01"

    enum CompletionTransport: Equatable, Sendable {
        case chatCompletions
        case anthropicMessages
    }

    /// Builds a chat completions URL from a user-provided base URL, stripping
    /// any trailing `/v1` or `/v1/chat/completions` to avoid double-pathing.
    static func chatCompletionsURL(from rawBase: String) -> URL? {
        let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }

        for suffix in ["/v1/chat/completions", "/v1"] {
            if path.hasSuffix(suffix) {
                path.removeLast(suffix.count)
                break
            }
        }

        if path.isEmpty {
            components.path = "/v1/chat/completions"
        } else {
            components.path = path + "/v1/chat/completions"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Builds an Anthropic Messages URL from a user-provided base URL, stripping
    /// trailing `/v1` or `/v1/messages` before appending the canonical path.
    static func anthropicMessagesURL(from rawBase: String) -> URL? {
        let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }

        for suffix in ["/v1/messages", "/v1"] {
            if path.hasSuffix(suffix) {
                path.removeLast(suffix.count)
                break
            }
        }

        components.path = path.isEmpty ? "/v1/messages" : path + "/v1/messages"
        components.query = nil
        components.fragment = nil
        return components.url
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

    static func preflightError(for url: URL, apiKey: String?) -> OpenRouterError? {
        guard let host = url.host?.lowercased(), host.contains("openrouter.ai") else {
            return nil
        }

        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingAPIKey(host: host)
        }

        return nil
    }

    /// Streams the completion response, yielding text chunks.
    func streamCompletion(
        apiKey: String? = nil,
        model: String,
        messages: [Message],
        maxTokens: Int = 1024,
        baseURL: URL? = nil,
        transport: CompletionTransport = .chatCompletions
    ) -> AsyncThrowingStream<String, Error> {
        if transport == .anthropicMessages {
            return streamAnthropicCompletion(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: maxTokens,
                baseURL: baseURL
            )
        }

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let targetURL = baseURL ?? Self.defaultBaseURL
                    if let preflightError = Self.preflightError(for: targetURL, apiKey: apiKey) {
                        continuation.finish(throwing: preflightError)
                        return
                    }
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
                    // Idle timeout between streamed bytes. Must cover cold-start of local models
                    // (Ollama/MLX) and first-token latency of reasoning models, which routinely
                    // exceed URLRequest's 60s default.
                    urlRequest.timeoutInterval = 300
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
        webSearch: Bool = false,
        transport: CompletionTransport = .chatCompletions,
        requestTimeout: TimeInterval = 300
    ) async throws -> String {
        if transport == .anthropicMessages {
            return try await completeAnthropic(
                apiKey: apiKey,
                model: model,
                messages: messages,
                maxTokens: maxTokens,
                temperature: temperature,
                baseURL: baseURL,
                requestTimeout: requestTimeout
            )
        }

        let targetURL = baseURL ?? Self.defaultBaseURL
        if let preflightError = Self.preflightError(for: targetURL, apiKey: apiKey) {
            throw preflightError
        }
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
        // Total request timeout — covers gate / judge / structured-JSON calls that may hit
        // slow local models or reasoning models. Default 60s is too aggressive in practice.
        urlRequest.timeoutInterval = requestTimeout
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

    private func streamAnthropicCompletion(
        apiKey: String?,
        model: String,
        messages: [Message],
        maxTokens: Int,
        baseURL: URL?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let targetURL = baseURL ?? Self.anthropicMessagesURL(from: "https://api.anthropic.com")!
                    guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.finish(throwing: OpenRouterError.missingAPIKey(host: targetURL.host))
                        return
                    }

                    let request = AnthropicRequest(
                        model: model,
                        max_tokens: maxTokens,
                        messages: Self.anthropicMessages(from: messages),
                        stream: true,
                        temperature: nil,
                        system: Self.anthropicSystemPrompt(from: messages)
                    )

                    var urlRequest = URLRequest(url: targetURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 300
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
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
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else {
                            continue
                        }
                        if event.type == "message_stop" { break }
                        if event.type == "content_block_delta",
                           event.delta?.type == "text_delta",
                           let text = event.delta?.text {
                            continuation.yield(text)
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

    private func completeAnthropic(
        apiKey: String?,
        model: String,
        messages: [Message],
        maxTokens: Int,
        temperature: Double?,
        baseURL: URL?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        let targetURL = baseURL ?? Self.anthropicMessagesURL(from: "https://api.anthropic.com")!
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterError.missingAPIKey(host: targetURL.host)
        }

        let request = AnthropicRequest(
            model: model,
            max_tokens: maxTokens,
            messages: Self.anthropicMessages(from: messages),
            stream: false,
            temperature: temperature,
            system: Self.anthropicSystemPrompt(from: messages)
        )

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenRouterError.httpError(statusCode, host: targetURL.host)
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return decoded.content.compactMap(\.text).joined()
    }

    private static func anthropicSystemPrompt(from messages: [Message]) -> String? {
        let prompt = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private static func anthropicMessages(from messages: [Message]) -> [AnthropicMessage] {
        messages.compactMap { message in
            guard message.role != "system" else { return nil }
            let role = message.role == "assistant" ? "assistant" : "user"
            return AnthropicMessage(role: role, content: message.content)
        }
    }

    enum OpenRouterError: Error, LocalizedError {
        case httpError(Int, host: String?)
        case missingAPIKey(host: String?)

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
            case .missingAPIKey(let host):
                let provider = switch host {
                case let h? where h.contains("openrouter.ai"): "OpenRouter"
                case let h?: h
                case nil: "LLM"
                }
                return "\(provider) API key required"
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

    private struct AnthropicRequest: Codable {
        let model: String
        let max_tokens: Int
        let messages: [AnthropicMessage]
        let stream: Bool
        let temperature: Double?
        let system: String?
    }

    private struct AnthropicMessage: Codable {
        let role: String
        let content: String
    }

    private struct AnthropicStreamEvent: Codable {
        let type: String
        let delta: Delta?

        struct Delta: Codable {
            let type: String
            let text: String?
        }
    }

    private struct AnthropicResponse: Codable {
        let content: [ContentBlock]

        struct ContentBlock: Codable {
            let type: String
            let text: String?
        }
    }
}
