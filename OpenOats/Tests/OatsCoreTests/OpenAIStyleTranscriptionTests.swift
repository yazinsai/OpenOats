import Foundation
import OatsCore
import Testing

/// Seam 3: the OpenAI-style `/audio/transcriptions` wire contract against stubbed HTTP.
@Suite final class OpenAIStyleTranscriptionTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers, try! JSONSerialization.data(withJSONObject: object))
    }

    static let oneSegment = json(["text": "Hello there.", "segments": [["start": 0.5, "end": 1.0, "text": " Hello there."]]])

    /// A Mic track of `seconds` tone with silence (cut points) at the given times.
    func track(seconds: Double, silentAt: [Double] = []) throws -> URL {
        var data = ws.pcm(seconds: seconds)
        for t in silentAt {
            let range = Int(t * 16_000) * 2..<Int((t + 0.1) * 16_000) * 2
            data.replaceSubrange(range, with: Data(count: range.count))
        }
        try FileManager.default.createDirectory(at: ws.root, withIntermediateDirectories: true)
        let url = ws.root.appendingPathComponent("mic.pcm")
        try data.write(to: url)
        return url
    }

    func uploadedSeconds(_ request: URLRequest) throws -> Double {
        let url = ws.root.appendingPathComponent("\(UUID().uuidString).m4a")
        try #require(formParts(of: request).first { $0.name == "file" }).data.write(to: url)
        return TrackAudio.duration(of: url)
    }

    @Test func uploadsTheTrackToTheAddressWithKeyModelAndLanguage() async throws {
        let stub = StubHTTP { _, _ in Self.oneSegment }
        let backend = try OpenAIStyleTranscription(address: stub.base, model: "whisper-large-v3", apiKey: "sk-test", session: stub.session)

        let segments = try await backend.transcribe(try track(seconds: 2), language: "en-US")

        #expect(segments == [TimedSegment(start: 0.5, end: 1.0, text: "Hello there.")])
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(stub.base)/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let form = formParts(of: request)
        #expect(form["model"] == "whisper-large-v3")
        #expect(form["language"] == "en")
        #expect(form["response_format"] == "verbose_json")
        #expect(form["timestamp_granularities[]"] == "segment")
        #expect(form.first { $0.name == "file" }?.filename == "audio.m4a")
        #expect(abs(try uploadedSeconds(request) - 2) < 0.05)
        #expect(backend.name == "openai-style:whisper-large-v3")
    }

    @Test func selfHostedServerWithoutKeyGetsNoAuthorizationOrLanguage() async throws {
        let stub = StubHTTP { _, _ in Self.oneSegment }
        let backend = try OpenAIStyleTranscription(address: stub.base, apiKey: "", session: stub.session)

        _ = try await backend.transcribe(try track(seconds: 1), language: nil)

        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(formParts(of: request)["language"] == nil)
        #expect(formParts(of: request)["model"] == "whisper-1")
    }

    @Test func rejectsANonHTTPAddress() {
        #expect(throws: CloudError.badAddress("ftp://x")) { try OpenAIStyleTranscription(address: "ftp://x", apiKey: nil) }
    }

    @Test func longTrackIsChunkedAtQuietPointsAndSegmentsShiftedByChunkOffset() async throws {
        let stub = StubHTTP { _, _ in Self.oneSegment }
        var backend = try OpenAIStyleTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.chunkSeconds = 2

        let segments = try await backend.transcribe(try track(seconds: 5, silentAt: [1.85, 3.85]), language: "en")

        #expect(stub.requests.count == 3)
        let lengths = try stub.requests.map(uploadedSeconds)
        #expect(lengths.allSatisfy { $0 <= 2.01 })
        #expect(abs(lengths.reduce(0, +) - 5) < 0.05)
        let offsets = segments.map { $0.start - 0.5 }
        #expect(offsets.count == 3 && offsets[0] == 0)
        #expect((1.84...1.96).contains(offsets[1]) && (3.84...3.96).contains(offsets[2]))
        #expect(abs(offsets[1] - lengths[0]) < 0.02 && abs(offsets[2] - lengths[0] - lengths[1]) < 0.02)
        #expect(segments.map(\.text) == Array(repeating: "Hello there.", count: 3))
    }

    @Test func textOnlyModelAsksForJSONAndSpansTheChunk() async throws {
        let stub = StubHTTP { _, _ in Self.json(["text": " Just text. "]) }
        let backend = try OpenAIStyleTranscription(address: stub.base, model: "gpt-4o-mini-transcribe", apiKey: "k", session: stub.session)

        let segments = try await backend.transcribe(try track(seconds: 2), language: "en")

        let form = formParts(of: try #require(stub.requests.first))
        #expect(form["response_format"] == "json")
        #expect(form["timestamp_granularities[]"] == nil)
        #expect(segments.count == 1 && segments[0].text == "Just text." && segments[0].start == 0)
        #expect(abs(segments[0].end - 2) < 0.05)
    }

    @Test func retriesRateLimitsServerErrorsAndTimeoutsWithBackoff() async throws {
        let stub = StubHTTP { _, attempt in
            switch attempt {
            case 1: Self.json([:], status: 429, headers: ["Retry-After": "7"])
            case 2: Self.json([:], status: 503)
            case 3: throw URLError(.timedOut)
            default: Self.oneSegment
            }
        }
        let sleeps = SleepLog()
        var backend = try OpenAIStyleTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.client.sleep = { await sleeps.add($0) }

        let segments = try await backend.transcribe(try track(seconds: 1), language: nil)

        #expect(segments.count == 1)
        #expect(stub.requests.count == 4)
        #expect(await sleeps.all == [.seconds(7), .seconds(14), .seconds(28)])
    }

    @Test func givesUpAfterFiveServerErrors() async throws {
        let stub = StubHTTP { _, _ in Self.json(["error": ["message": "overloaded"]], status: 500) }
        var backend = try OpenAIStyleTranscription(address: stub.base, apiKey: "k", session: stub.session)
        backend.client.sleep = { _ in }

        await #expect(throws: CloudError.http(backend: stub.host, status: 500, message: "overloaded")) {
            try await backend.transcribe(try self.track(seconds: 1), language: nil)
        }
        #expect(stub.requests.count == 5)
    }

    @Test func rejectedKeyAndBadRequestFailWithoutRetry() async throws {
        let unauthorized = StubHTTP { _, _ in Self.json(["error": ["message": "Incorrect API key provided: sk-…"]], status: 401) }
        let badRequest = StubHTTP { _, _ in Self.json(["error": ["message": "model 'nope' not found"]], status: 400) }
        var a = try OpenAIStyleTranscription(address: unauthorized.base, apiKey: "k", session: unauthorized.session)
        var b = try OpenAIStyleTranscription(address: badRequest.base, model: "nope", apiKey: "k", session: badRequest.session)
        a.client.sleep = { _ in }
        b.client.sleep = { _ in }
        let audio = try track(seconds: 1)

        await #expect(throws: CloudError.invalidKey(backend: unauthorized.host)) { try await a.transcribe(audio, language: nil) }
        await #expect(throws: CloudError.http(backend: badRequest.host, status: 400, message: "model 'nope' not found")) {
            try await b.transcribe(audio, language: nil)
        }
        #expect(unauthorized.requests.count == 1 && badRequest.requests.count == 1)
    }

    @Test func unreadableReplyIsABadResponse() async throws {
        let stub = StubHTTP { _, _ in (200, [:], Data("<html>".utf8)) }
        let backend = try OpenAIStyleTranscription(address: stub.base, apiKey: "k", session: stub.session)
        await #expect(throws: CloudError.badResponse(backend: stub.host)) { try await backend.transcribe(try self.track(seconds: 1), language: nil) }
    }
}

actor SleepLog {
    private(set) var all: [Duration] = []
    func add(_ d: Duration) { all.append(d) }
}
