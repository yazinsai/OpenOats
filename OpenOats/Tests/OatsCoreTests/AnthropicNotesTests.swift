import Foundation
import OatsCore
import Testing

/// Seam 3: the Anthropic Messages Notes backend's wire contract against stubbed HTTP.
@Suite struct AnthropicNotesTests {
    func backend(_ stub: StubHTTP, address: String? = nil, model: String? = "claude-sonnet-4-5", key: String? = "sk-ant-test") -> AnthropicNotes {
        var backend = AnthropicNotes(BackendSetup(type: .anthropic, address: address ?? "https://\(stub.host)", model: model,
                                                  apiKey: key, contextTokens: 128_000), session: stub.session)
        backend.client.sleep = { _ in }
        return backend
    }

    static func reply(_ texts: [String], stop: String = "end_turn") -> (Int, [String: String], Data) {
        json(["type": "message", "role": "assistant", "stop_reason": stop,
              "content": texts.map { ["type": "text", "text": $0] } + [["type": "tool_use", "id": "x", "name": "n", "input": [:]]]])
    }

    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test func sendsSystemAndUserToMessagesWithKeyAndVersion() async throws {
        let stub = StubHTTP { _, _ in Self.reply(["Title: Sync\n\n", "## Summary\nDone. "]) }
        let text = try await backend(stub).complete(system: "You write notes.", user: "[00:00:01] You: hello")

        #expect(text == "Title: Sync\n\n## Summary\nDone.")
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://\(stub.host)/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let sent = body(request)
        #expect(sent["model"] as? String == "claude-sonnet-4-5")
        #expect(sent["system"] as? String == "You write notes.")
        #expect((sent["max_tokens"] as? Int ?? 0) >= 4_096)
        #expect(sent["messages"] as? [[String: String]] == [["role": "user", "content": "[00:00:01] You: hello"]])
        #expect(backend(stub).name == "anthropic:claude-sonnet-4-5")
    }

    @Test(arguments: ["", "/", "/v1", "/v1/", "/v1/messages"])
    func acceptsEveryPastedAddressVariant(_ suffix: String) async throws {
        let stub = StubHTTP { _, _ in Self.reply(["ok"]) }
        _ = try await backend(stub, address: "https://\(stub.host)\(suffix)").complete(system: "s", user: "u")
        #expect(stub.requests.first?.url?.absoluteString == "https://\(stub.host)/v1/messages")
    }

    @Test func retriesOverloadedThenSucceeds() async throws {
        let stub = StubHTTP { _, attempt in
            attempt == 1 ? json(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], status: 529) : Self.reply(["ok"])
        }
        #expect(try await backend(stub).complete(system: "s", user: "u") == "ok")
        #expect(stub.requests.count == 2)
    }

    @Test func errorsMissingKeyAndEmptyRepliesFail() async throws {
        let bad = StubHTTP { _, _ in
            json(["type": "error", "error": ["type": "not_found_error", "message": "model: claude-nope"]], status: 404)
        }
        await #expect(throws: CloudError.http(backend: "Anthropic", status: 404, message: "model: claude-nope")) {
            try await backend(bad, model: "claude-nope").complete(system: "s", user: "u")
        }
        #expect(bad.requests.count == 1)
        let rejected = StubHTTP { _, _ in json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]], status: 401) }
        await #expect(throws: CloudError.invalidKey(backend: "Anthropic")) { try await backend(rejected).complete(system: "s", user: "u") }
        await #expect(throws: CloudError.invalidKey(backend: "Anthropic")) { try await backend(rejected, key: nil).complete(system: "s", user: "u") }
        #expect(rejected.requests.count == 1, "no request without a key")
        let empty = StubHTTP { _, _ in Self.reply([" "], stop: "max_tokens") }
        await #expect(throws: NotesError.self) { try await backend(empty).complete(system: "s", user: "u") }
        let garbage = StubHTTP { _, _ in (200, [:], Data("<html>".utf8)) }
        await #expect(throws: CloudError.badResponse(backend: "Anthropic")) { try await backend(garbage).complete(system: "s", user: "u") }
    }

    @Test func builtInMakersBuildAnthropicFromItsPreset() throws {
        let preset = try #require(Preset<NotesBackendType>.all.first { $0.type == .anthropic })
        let setup = BackendSetup(type: preset.type, address: preset.address, model: preset.model, apiKey: "k", contextTokens: 0)
        #expect(BackendMakers.builtIn.notes[.anthropic]?(setup).name == "anthropic:claude-sonnet-4-5")
    }
}
