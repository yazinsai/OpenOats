import Foundation

/// The Anthropic Notes backend: the native Messages API (`POST …/v1/messages`), non-streaming.
public struct AnthropicNotes: NotesBackend {
    public var address: String
    public var model: String
    public var apiKey: String?
    public var contextTokens: Int
    public var client: CloudClient

    public var name: String { "anthropic:\(model)" }

    public init(_ setup: BackendSetup<NotesBackendType>, session: URLSession = URLSession(configuration: .ephemeral)) {
        address = setup.address ?? "https://api.anthropic.com"
        model = setup.model ?? "claude-sonnet-4-5"
        apiKey = setup.apiKey?.isEmpty == false ? setup.apiKey : nil
        contextTokens = setup.contextTokens
        client = CloudClient(backend: "Anthropic", session: session)
    }

    /// Accepts `host`, `host/v1` or the full `…/v1/messages`.
    var endpoint: URL? {
        var s = address.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/messages", "/v1"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        guard let url = URL(string: s + "/v1/messages"), url.scheme?.hasPrefix("http") == true, url.host() != nil else { return nil }
        return url
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let url = endpoint else { throw CloudError.badAddress(address) }
        guard let apiKey else { throw CloudError.invalidKey(backend: client.backend) }
        let body: [String: Any] = ["model": model, "max_tokens": 8_192, "system": system, "messages": [["role": "user", "content": user]]]
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await client.send(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]] else { throw CloudError.badResponse(backend: client.backend) }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.empty }
        return text
    }
}
