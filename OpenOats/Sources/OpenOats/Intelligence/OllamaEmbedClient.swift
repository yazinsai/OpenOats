import Foundation

/// Client for Ollama and OpenAI-compatible embeddings endpoints.
actor OllamaEmbedClient {
    enum EmbedClientError: Error, LocalizedError {
        case httpError(Int, String, provider: String)
        case invalidURL(provider: String)
        case emptyResponse(provider: String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let msg, let provider): "\(provider) embed error (HTTP \(code)): \(msg)"
            case .invalidURL(let provider): "Invalid \(provider) base URL"
            case .emptyResponse(let provider): "Empty response from \(provider) embeddings"
            }
        }
    }

    func embed(texts: [String], baseURL: String, model: String, apiKey: String? = nil) async throws -> [[Float]] {
        let providerName = apiKey != nil ? "OpenAI Compatible" : "Ollama"
        let normalized = Self.normalizeBaseURL(baseURL)
        guard let url = URL(string: normalized + "/v1/embeddings") else {
            throw EmbedClientError.invalidURL(provider: providerName)
        }

        let body = EmbedRequest(model: model, input: texts)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw EmbedClientError.httpError(-1, "No HTTP response", provider: providerName)
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EmbedClientError.httpError(http.statusCode, msg, provider: providerName)
        }

        let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        guard !decoded.data.isEmpty else { throw EmbedClientError.emptyResponse(provider: providerName) }

        return decoded.data
            .sorted { $0.index < $1.index }
            .map { $0.embedding }
    }

    /// Strips trailing slashes and a trailing `/v1` path segment so callers
    /// can enter either `http://localhost:11434` or `http://localhost:11434/v1`.
    static func normalizeBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if url.hasSuffix("/v1") {
            url = String(url.dropLast(3))
        }
        return url
    }

    // MARK: - Request/Response Types

    private struct EmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbedResponse: Decodable {
        let data: [EmbeddingData]

        struct EmbeddingData: Decodable {
            let index: Int
            let embedding: [Float]
        }
    }
}
