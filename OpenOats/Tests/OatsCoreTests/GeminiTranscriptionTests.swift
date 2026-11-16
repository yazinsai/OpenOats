import Foundation
import OatsCore
import Testing

/// Seam 3: the Gemini `generateContent` audio wire contract against stubbed HTTP.
@Suite final class GeminiTranscriptionTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    static func reply(_ items: [[String: String]]) -> (Int, [String: String], Data) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: items), as: UTF8.self)
        return json(["candidates": [["content": ["parts": [["text": text]], "role": "model"], "finishReason": "STOP"]]])
    }

    static let twoSentences = reply([
        ["start": "00:00.5", "end": "00:01.2", "text": " Hello there. "], ["start": "00:01.4", "end": "00:09", "text": "Bye."], ["start": "0:01", "end": "0:01", "text": " "],
    ])

    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test func sendsTheChunkInlineWithKeyAndSchemaAndReadsTimedSentences() async throws {
        let stub = StubHTTP { _, _ in Self.twoSentences }
        let backend = GeminiTranscription(address: stub.base, apiKey: "g-test", session: stub.session)

        let segments = try await backend.transcribe(try ws.track(seconds: 2), language: "fr")

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(stub.base)/models/gemini-3-flash-preview:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-test")
        let json = body(request)
        let parts = try #require(((json["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        #expect((parts[0]["text"] as? String)?.contains("(language: fr)") == true)
        let inline = try #require(parts[1]["inline_data"] as? [String: String])
        #expect(inline["mime_type"] == "audio/mp4")
        let uploaded = ws.root.appendingPathComponent("up.m4a")
        try #require(Data(base64Encoded: inline["data"] ?? "")).write(to: uploaded)
        #expect(abs(TrackAudio.duration(of: uploaded) - 2) < 0.05)
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json" && config["responseSchema"] != nil)
        #expect(segments.map(\.text) == ["Hello there.", "Bye."])
        #expect(segments[0].start == 0.5 && segments[0].end == 1.2 && segments[1].start == 1.4)
        #expect(abs(segments[1].end - 2) < 0.05, "end clamped to the chunk")
        #expect(segments.allSatisfy { $0.speaker == nil } && !backend.separatesSpeakers)
        #expect(backend.name == "gemini:gemini-3-flash-preview")
    }

    @Test func longTrackIsChunkedAndSegmentsShiftedByChunkOffset() async throws {
        let stub = StubHTTP { _, _ in Self.reply([["start": "00:00.5", "end": "00:01", "text": "Hi."]]) }
        var backend = GeminiTranscription(address: stub.base, model: "gemini-2.5-pro", apiKey: "k", session: stub.session)
        backend.chunkSeconds = 2

        let segments = try await backend.transcribe(try ws.track(seconds: 5, silentAt: [1.85, 3.85]), language: nil)

        #expect(stub.requests.count == 3)
        #expect(stub.requests.allSatisfy { $0.url!.path.hasSuffix("/models/gemini-2.5-pro:generateContent") })
        let offsets = segments.map { $0.start - 0.5 }
        #expect(offsets.count == 3 && offsets[0] == 0)
        #expect((1.84...1.96).contains(offsets[1]) && (3.84...3.96).contains(offsets[2]))
    }

    @Test func retriesOverloadThenSucceeds() async throws {
        let stub = StubHTTP { _, attempt in attempt == 1 ? json(["error": ["code": 503, "message": "The model is overloaded."]], status: 503) : Self.twoSentences }
        var backend = GeminiTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.client.sleep = { _ in }
        #expect(try await backend.transcribe(try ws.track(seconds: 2), language: nil).count == 2)
        #expect(stub.requests.count == 2)
    }

    @Test func errorsMissingKeyAndUnreadableRepliesFail() async throws {
        let audio = try ws.track(seconds: 1)
        let badKey = StubHTTP { _, _ in json(["error": ["code": 400, "message": "API key not valid.", "status": "INVALID_ARGUMENT"]], status: 400) }
        await #expect(throws: CloudError.http(backend: "Gemini", status: 400, message: "API key not valid.")) {
            try await GeminiTranscription(address: badKey.base, apiKey: "k", session: badKey.session).transcribe(audio, language: nil)
        }
        #expect(badKey.requests.count == 1)
        await #expect(throws: CloudError.invalidKey(backend: "Gemini")) {
            try await GeminiTranscription(address: badKey.base, apiKey: nil, session: badKey.session).transcribe(audio, language: nil)
        }
        let truncated = StubHTTP { _, _ in json(["candidates": [["content": ["parts": [["text": "[{\"start\": \"00:0"]]], "finishReason": "MAX_TOKENS"]]]) }
        await #expect(throws: CloudError.badResponse(backend: "Gemini")) {
            try await GeminiTranscription(address: truncated.base, apiKey: "k", session: truncated.session).transcribe(audio, language: nil)
        }
        let blocked = StubHTTP { _, _ in json(["candidates": [["finishReason": "SAFETY"]]]) }
        await #expect(throws: CloudError.badResponse(backend: "Gemini")) {
            try await GeminiTranscription(address: blocked.base, apiKey: "k", session: blocked.session).transcribe(audio, language: nil)
        }
    }

    @Test func builtInMakersBuildGeminiFromItsPreset() throws {
        let preset = try #require(Preset<TranscriptionBackendType>.all.first { $0.type == .gemini })
        let setup = BackendSetup(type: preset.type, address: preset.address, model: preset.model, apiKey: "k", contextTokens: 0)
        #expect(BackendMakers.builtIn.transcription[.gemini]?(setup).name == "gemini:gemini-3-flash-preview")
    }
}
