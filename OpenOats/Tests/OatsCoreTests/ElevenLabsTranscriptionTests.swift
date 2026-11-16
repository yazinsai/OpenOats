import Foundation
import OatsCore
import Testing

extension Workspace {
    /// A track file `<name>.pcm` of `seconds` tone with 100 ms of silence (cut points) at the given times.
    func track(_ name: String = "mic", seconds: Double, silentAt: [Double] = []) throws -> URL {
        var data = pcm(seconds: seconds)
        for t in silentAt {
            let range = Int(t * 16_000) * 2..<Int((t + 0.1) * 16_000) * 2
            data.replaceSubrange(range, with: Data(count: range.count))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(name).pcm")
        try data.write(to: url)
        return url
    }
}

func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
    (status, headers, try! JSONSerialization.data(withJSONObject: object))
}

/// Seam 3: the ElevenLabs Scribe wire contract against stubbed HTTP.
@Suite final class ElevenLabsTranscriptionTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    static func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String = "speaker_0", type: String = "word") -> [String: Any] {
        ["text": text, "start": start, "end": end, "type": type, "speaker_id": speaker]
    }

    static let reply = json(["text": "Hi there. Yes, go.", "words": [
        word("Hi", 0.1, 0.3), word(" ", 0.3, 0.35, type: "spacing"), word("there.", 0.35, 0.6),
        word("(laughs)", 0.6, 0.7, type: "audio_event"), word("Yes", 0.8, 1.0, "speaker_1"), word(",", 1.0, 1.0, "speaker_1"),
        word("go", 2.5, 2.7, "speaker_1"),
    ]])

    @Test func uploadsTheTrackWithKeyModelAndLanguageAndGroupsWordsIntoSentences() async throws {
        let stub = StubHTTP { _, _ in Self.reply }
        let backend = ElevenLabsTranscription(address: stub.base, apiKey: "xi-test", session: stub.session)

        let segments = try await backend.transcribe(try ws.track(seconds: 2), language: "de-DE")

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(stub.base)/speech-to-text")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-test")
        let form = formParts(of: request)
        #expect(form["model_id"] == "scribe_v2")
        #expect(form["language_code"] == "de")
        #expect(form["diarize"] == nil)
        #expect(form.first { $0.name == "file" }?.filename == "audio.m4a")
        #expect(segments.map(\.text) == ["Hi there.", "Yes,", "go"])
        #expect(segments.map(\.start) == [0.1, 0.8, 2.5] && segments.map(\.end) == [0.6, 1.0, 2.7])
        #expect(backend.name == "elevenlabs:scribe_v2")
    }

    @Test func mixedImportIsDiarizedIntoNumberedSpeakers() async throws {
        let stub = StubHTTP { _, _ in Self.reply }
        let backend = ElevenLabsTranscription(address: stub.base, apiKey: "k", session: stub.session)

        let segments = try await backend.transcribe(try ws.track("mixed", seconds: 2), language: nil)

        let form = formParts(of: try #require(stub.requests.first))
        #expect(form["diarize"] == "true" && form["language_code"] == nil)
        #expect(backend.separatesSpeakers)
        #expect(segments.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @Test func longTrackIsChunkedAndWordsShiftedByChunkOffset() async throws {
        let stub = StubHTTP { _, _ in json(["words": [Self.word("Hello.", 0.5, 1.0)]]) }
        var backend = ElevenLabsTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.chunkSeconds = 2

        let segments = try await backend.transcribe(try ws.track(seconds: 5, silentAt: [1.85, 3.85]), language: nil)

        #expect(stub.requests.count == 3)
        let offsets = segments.map { $0.start - 0.5 }
        #expect(offsets.count == 3 && offsets[0] == 0)
        #expect((1.84...1.96).contains(offsets[1]) && (3.84...3.96).contains(offsets[2]))
    }

    @Test func retriesServerErrorsThenSucceeds() async throws {
        let stub = StubHTTP { _, attempt in attempt == 1 ? json([:], status: 429) : (attempt == 2 ? json([:], status: 502) : Self.reply) }
        let sleeps = SleepLog()
        var backend = ElevenLabsTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.client.sleep = { await sleeps.add($0) }

        #expect(try await backend.transcribe(try ws.track(seconds: 1), language: nil).count == 3)
        #expect(stub.requests.count == 3)
        #expect(await sleeps.all == [.seconds(1), .seconds(2)])
    }

    @Test func rejectedOrMissingKeyAndBadRequestFail() async throws {
        let unauthorized = StubHTTP { _, _ in json(["detail": ["status": "invalid_api_key"]], status: 401) }
        let badRequest = StubHTTP { _, _ in json(["detail": "Invalid language code"], status: 400) }
        let unreadable = StubHTTP { _, _ in (200, [:], Data("<html>".utf8)) }
        let audio = try ws.track(seconds: 1)

        await #expect(throws: CloudError.invalidKey(backend: "ElevenLabs")) {
            try await ElevenLabsTranscription(address: unauthorized.base, apiKey: "k", session: unauthorized.session).transcribe(audio, language: nil)
        }
        await #expect(throws: CloudError.invalidKey(backend: "ElevenLabs")) {
            try await ElevenLabsTranscription(address: unauthorized.base, apiKey: "", session: unauthorized.session).transcribe(audio, language: nil)
        }
        await #expect(throws: CloudError.http(backend: "ElevenLabs", status: 400, message: "Invalid language code")) {
            try await ElevenLabsTranscription(address: badRequest.base, apiKey: "k", session: badRequest.session).transcribe(audio, language: "xx")
        }
        await #expect(throws: CloudError.badResponse(backend: "ElevenLabs")) {
            try await ElevenLabsTranscription(address: unreadable.base, apiKey: "k", session: unreadable.session).transcribe(audio, language: nil)
        }
        #expect(unauthorized.requests.count == 1 && badRequest.requests.count == 1)
    }

    @Test func builtInMakersBuildElevenLabsFromItsPreset() throws {
        let preset = try #require(Preset<TranscriptionBackendType>.all.first { $0.type == .elevenLabs })
        let setup = BackendSetup(type: preset.type, address: preset.address, model: preset.model, apiKey: "k", contextTokens: 0)
        #expect(BackendMakers.builtIn.transcription[.elevenLabs]?(setup).name == "elevenlabs:scribe_v2")
    }
}
