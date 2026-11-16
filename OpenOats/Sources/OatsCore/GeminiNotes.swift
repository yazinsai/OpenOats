import Foundation

/// The Gemini Notes backend: `POST …/models/<model>:generateContent` with the notes prompt as the system instruction.
public struct GeminiNotes: NotesBackend {
    public var address: String
    public var model: String
    public var apiKey: String?
    public var contextTokens: Int
    public var client: CloudClient

    public var name: String { "gemini:\(model)" }

    public init(_ setup: BackendSetup<NotesBackendType>, session: URLSession = URLSession(configuration: .ephemeral)) {
        address = setup.address ?? GeminiTranscription.defaultAddress
        model = setup.model ?? "gemini-3-flash-preview"
        apiKey = setup.apiKey?.isEmpty == false ? setup.apiKey : nil
        contextTokens = setup.contextTokens
        client = CloudClient(backend: "Gemini", session: session)
    }

    public func complete(system: String, user: String) async throws -> String {
        var base = address.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), url.scheme?.hasPrefix("http") == true, url.host() != nil else { throw CloudError.badAddress(address) }
        guard let apiKey else { throw CloudError.invalidKey(backend: client.backend) }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
        ]
        var request = URLRequest(url: url.appendingPathComponent("models/\(model):generateContent"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await client.send(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidate = (json?["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        else { throw CloudError.badResponse(backend: client.backend) } // e.g. a blocked prompt
        let text = parts.compactMap { $0["thought"] as? Bool == true ? nil : $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.empty }
        return text
    }
}
