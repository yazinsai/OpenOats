import Foundation
import OatsCore
import Testing

/// Seam 3: the OpenAI-compatible Notes backend's wire contract against stubbed HTTP.
@Suite struct OpenAICompatibleNotesTests {
    func backend(_ stub: StubHTTP, address: String? = nil, model: String? = "gpt-4.1-mini", key: String? = "sk-test",
                 contextTokens: Int = 128_000) -> OpenAICompatibleNotes {
        var backend = OpenAICompatibleNotes(BackendSetup(type: .openAICompatible, address: address ?? stub.base, model: model,
                                                         apiKey: key, contextTokens: contextTokens), session: stub.session)
        backend.client.sleep = { _ in }
        return backend
    }

    static func reply(_ message: [String: Any]) -> (Int, [String: String], Data) {
        (200, [:], try! JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": "stop"]]]))
    }

    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test func sendsSystemAndUserToChatCompletionsWithTheKey() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["role": "assistant", "content": "Title: Sync\n\n## Summary\nDone."]) }
        let text = try await backend(stub).complete(system: "You write notes.", user: "[00:00:01] You: hello")

        #expect(text == "Title: Sync\n\n## Summary\nDone.")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://\(stub.host)/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = body(request)
        #expect(sent["model"] as? String == "gpt-4.1-mini")
        #expect(sent["stream"] as? Bool == false)
        let messages = try #require(sent["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "You write notes."], ["role": "user", "content": "[00:00:01] You: hello"]])
    }

    @Test(arguments: ["", "/", "/v1", "/v1/", "/v1/chat/completions"])
    func acceptsEveryPastedAddressVariant(_ suffix: String) async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "ok"]) }
        _ = try await backend(stub, address: "https://\(stub.host)\(suffix)").complete(system: "s", user: "u")
        #expect(stub.requests.first?.url?.absoluteString == "https://\(stub.host)/v1/chat/completions")
    }

    @Test func keepsAProviderPathBeforeV1() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "ok"]) }
        _ = try await backend(stub, address: "https://\(stub.host)/api/v1").complete(system: "s", user: "u")
        #expect(stub.requests.first?.url?.path() == "/api/v1/chat/completions")
    }

    @Test func localServerWithoutKeyOrModelSendsNeither() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "ok"]) }
        _ = try await backend(stub, model: nil, key: nil).complete(system: "s", user: "u")
        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body(request)["model"] == nil)
    }

    @Test func ollamaGetsItsNativeChatWithTheContextSize() async throws {
        let stub = StubHTTP { _, _ in
            (200, [:], Data(#"{"message":{"role":"assistant","content":"Title: Plan\n\nNotes."},"done":true}"#.utf8))
        }
        let text = try await backend(stub, address: "http://\(stub.host):11434/v1", model: "qwen3:8b", key: nil, contextTokens: 8_192)
            .complete(system: "s", user: "u")

        #expect(text == "Title: Plan\n\nNotes.")
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "http://\(stub.host):11434/api/chat")
        let sent = body(request)
        #expect(sent["model"] as? String == "qwen3:8b")
        #expect((sent["options"] as? [String: Int])?["num_ctx"] == 8_192)
        #expect(sent["stream"] as? Bool == false)
        #expect(sent["think"] as? Bool == false)
    }

    @Test func dropsALeadingThinkBlock() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "<think>\nLet me see.\n</think>\n\nTitle: Sync\n\nNotes."]) }
        #expect(try await backend(stub).complete(system: "s", user: "u") == "Title: Sync\n\nNotes.")
    }

    @Test func reasoningOnlyReplyIsAnErrorNotEmptyNotes() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "", "reasoning": "The user wants notes…"]) }
        await #expect(throws: NotesError.self) { try await backend(stub).complete(system: "s", user: "u") }
    }

    @Test func clientErrorFailsAtOnceWithTheServersMessage() async throws {
        let stub = StubHTTP { _, _ in (404, [:], Data(#"{"error":{"message":"model 'qwen9' not found"}}"#.utf8)) }
        let error = await #expect(throws: CloudError.self) { try await backend(stub).complete(system: "s", user: "u") }
        #expect(error?.localizedDescription == "\(stub.host) request failed (HTTP 404): model 'qwen9' not found")
        #expect(stub.requests.count == 1)
    }

    @Test func rejectedKeyPointsToSettings() async throws {
        let stub = StubHTTP { _, _ in (401, [:], Data(#"{"error":"invalid api key"}"#.utf8)) }
        let error = await #expect(throws: CloudError.self) { try await backend(stub).complete(system: "s", user: "u") }
        #expect(error?.localizedDescription == "\(stub.host) rejected the API key. Check Settings > AI.")
    }

    @Test func retriesRateLimitsServerErrorsAndDroppedConnections() async throws {
        let stub = StubHTTP { _, attempt in
            switch attempt {
            case 1: (429, ["Retry-After": "1"], Data())
            case 2: throw URLError(.networkConnectionLost)
            default: Self.reply(["content": "ok"])
            }
        }
        #expect(try await backend(stub).complete(system: "s", user: "u") == "ok")
        #expect(stub.requests.count == 3)
    }

    @Test func givesUpAfterFiveServerErrors() async throws {
        let stub = StubHTTP { _, _ in (503, [:], Data(#"{"error":{"message":"upstream overloaded"}}"#.utf8)) }
        let error = await #expect(throws: CloudError.self) { try await backend(stub).complete(system: "s", user: "u") }
        #expect(error == .http(backend: stub.host, status: 503, message: "upstream overloaded"))
        #expect(stub.requests.count == 5)
    }

    @Test func testCallSendsOneTinyRequest() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["content": "OK"]) }
        try await backend(stub).test()
        #expect(stub.requests.count == 1)
    }

    @Test func settingsBuildThisBackendForTheOpenAICompatiblePresets() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: MemorySecrets())
        let ollama = Preset<NotesBackendType>.all.first { $0.name == "Ollama" }!
        #expect(store.notesBackend(ollama.config)?.name == "openai-compatible:qwen3:8b")
    }
}
