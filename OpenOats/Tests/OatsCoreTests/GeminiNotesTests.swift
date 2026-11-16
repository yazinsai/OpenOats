import Foundation
import OatsCore
import Testing

/// Seam 3: the Gemini `generateContent` Notes backend's wire contract against stubbed HTTP.
@Suite struct GeminiNotesTests {
    func backend(_ stub: StubHTTP, address: String? = nil, model: String? = "gemini-3-flash-preview", key: String? = "g-test") -> GeminiNotes {
        var backend = GeminiNotes(BackendSetup(type: .gemini, address: address ?? stub.base, model: model,
                                               apiKey: key, contextTokens: 128_000), session: stub.session)
        backend.client.sleep = { _ in }
        return backend
    }

    static func reply(_ parts: [[String: Any]], finish: String = "STOP") -> (Int, [String: String], Data) {
        json(["candidates": [["content": ["parts": parts, "role": "model"], "finishReason": finish]]])
    }

    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test func sendsSystemInstructionAndUserWithKeyAndSkipsThoughts() async throws {
        let stub = StubHTTP { _, _ in
            Self.reply([["text": "Let me think.", "thought": true], ["text": "Title: Sync\n\n"], ["text": "## Summary\nDone. ", "thoughtSignature": "abc"]])
        }
        let text = try await backend(stub).complete(system: "You write notes.", user: "[00:00:01] You: hello")

        #expect(text == "Title: Sync\n\n## Summary\nDone.")
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(stub.base)/models/gemini-3-flash-preview:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-test")
        #expect(request.url?.query == nil, "key never in the URL")
        let sent = body(request)
        let system = sent["systemInstruction"] as? [String: Any]
        #expect(system?["parts"] as? [[String: String]] == [["text": "You write notes."]])
        let contents = try #require(sent["contents"] as? [[String: Any]])
        #expect(contents.count == 1 && contents[0]["role"] as? String == "user")
        #expect(contents[0]["parts"] as? [[String: String]] == [["text": "[00:00:01] You: hello"]])
        #expect(backend(stub).name == "gemini:gemini-3-flash-preview")
    }

    @Test(arguments: ["", "/"])
    func acceptsATrailingSlash(_ suffix: String) async throws {
        let stub = StubHTTP { _, _ in Self.reply([["text": "ok"]]) }
        _ = try await backend(stub, address: stub.base + suffix, model: "gemini-2.5-pro").complete(system: "s", user: "u")
        #expect(stub.requests.first?.url?.absoluteString == "\(stub.base)/models/gemini-2.5-pro:generateContent")
    }

    @Test func retriesOverloadThenSucceeds() async throws {
        let stub = StubHTTP { _, attempt in
            attempt == 1 ? json(["error": ["code": 503, "message": "The model is overloaded.", "status": "UNAVAILABLE"]], status: 503)
                : Self.reply([["text": "ok"]])
        }
        #expect(try await backend(stub).complete(system: "s", user: "u") == "ok")
        #expect(stub.requests.count == 2)
    }

    @Test func errorsMissingKeyBlockedAndEmptyRepliesFail() async throws {
        let badKey = StubHTTP { _, _ in json(["error": ["code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"]], status: 400) }
        await #expect(throws: CloudError.http(backend: "Gemini", status: 400, message: "API key not valid.")) {
            try await backend(badKey).complete(system: "s", user: "u")
        }
        #expect(badKey.requests.count == 1)
        await #expect(throws: CloudError.invalidKey(backend: "Gemini")) { try await backend(badKey, key: nil).complete(system: "s", user: "u") }
        #expect(badKey.requests.count == 1, "no request without a key")
        let blocked = StubHTTP { _, _ in json(["promptFeedback": ["blockReason": "SAFETY"]]) }
        await #expect(throws: CloudError.badResponse(backend: "Gemini")) { try await backend(blocked).complete(system: "s", user: "u") }
        let thoughtsOnly = StubHTTP { _, _ in Self.reply([["text": "Hmm", "thought": true]], finish: "MAX_TOKENS") }
        await #expect(throws: NotesError.self) { try await backend(thoughtsOnly).complete(system: "s", user: "u") }
    }

    @Test func builtInMakersBuildGeminiFromItsPreset() throws {
        let preset = try #require(Preset<NotesBackendType>.all.first { $0.type == .gemini })
        let setup = BackendSetup(type: preset.type, address: preset.address, model: preset.model, apiKey: "k", contextTokens: 0)
        #expect(BackendMakers.builtIn.notes[.gemini]?(setup).name == "gemini:gemini-3-flash-preview")
    }
}
