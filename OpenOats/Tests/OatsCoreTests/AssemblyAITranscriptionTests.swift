import Foundation
import OatsCore
import Testing

/// Seam 3: the AssemblyAI upload → transcript → poll wire contract against stubbed HTTP.
@Suite final class AssemblyAITranscriptionTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    nonisolated(unsafe) static let words: [[String: Any]] = [
        ["text": "Hi", "start": 100, "end": 300, "speaker": "A"], ["text": "there.", "start": 350, "end": 600, "speaker": "A"],
        ["text": "Yes.", "start": 800, "end": 1000, "speaker": "B"],
    ]
    static let completed = json(["id": "t1", "status": "completed", "words": words])

    /// A stub AssemblyAI. `poll(n)` answers the n-th GET of the transcript (from 1).
    static func service(uploadHost: String? = nil, poll: @escaping @Sendable (Int) throws -> (Int, [String: String], Data) = { _ in completed }) -> StubHTTP {
        let polls = Counter()
        return StubHTTP { request, _ in
            let url = request.url!
            if url.path.hasSuffix("/upload") { return json(["upload_url": "https://\(uploadHost ?? url.host!)/upload/abc"]) }
            if url.path.hasSuffix("/transcript") { return json(["id": "t1", "status": "queued"]) }
            return try poll(polls.next())
        }
    }

    func backend(_ stub: StubHTTP, key: String = "aai-test") -> AssemblyAITranscription {
        var backend = AssemblyAITranscription(address: stub.base, apiKey: key, session: stub.session)
        backend.client.sleep = { _ in }
        return backend
    }

    func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test func uploadsCreatesAndPollsUntilCompletedThenGroupsWordsIntoSentences() async throws {
        let stub = Self.service { $0 < 3 ? json(["id": "t1", "status": "processing"]) : Self.completed }
        let sleeps = SleepLog()
        var backend = backend(stub)
        backend.client.sleep = { await sleeps.add($0) }

        let segments = try await backend.transcribe(try ws.track(seconds: 2), language: "en-GB")

        #expect(stub.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /v1/upload", "POST /v1/transcript"] + Array(repeating: "GET /v1/transcript/t1", count: 3))
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "aai-test" })
        let upload = stub.requests[0]
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let uploaded = ws.root.appendingPathComponent("up.m4a")
        try upload.httpBody?.write(to: uploaded)
        #expect(abs(TrackAudio.duration(of: uploaded) - 2) < 0.05)
        let job = body(stub.requests[1])
        #expect(job["audio_url"] as? String == "https://\(stub.host)/upload/abc")
        #expect(job["language_code"] as? String == "en" && job["language_detection"] == nil)
        #expect(job["speaker_labels"] as? Bool == false && job["speech_model"] == nil)
        #expect(await sleeps.all == [.seconds(3), .seconds(3), .seconds(3)])
        #expect(segments.map(\.text) == ["Hi there.", "Yes."])
        #expect(segments.map(\.start) == [0.1, 0.8] && segments.map(\.end) == [0.6, 1.0])
        #expect(backend.name == "assemblyai")
    }

    @Test func mixedImportGetsSpeakerLabelsAndLanguageDetection() async throws {
        let stub = Self.service()
        let segments = try await backend(stub).transcribe(try ws.track("mixed", seconds: 1), language: nil)

        let job = body(stub.requests[1])
        #expect(job["speaker_labels"] as? Bool == true && job["language_detection"] as? Bool == true && job["language_code"] == nil)
        #expect(backend(stub).separatesSpeakers)
        #expect(segments.map(\.speaker) == ["Speaker A", "Speaker B"])
    }

    @Test func longTrackIsChunkedAndWordsShiftedByChunkOffset() async throws {
        let stub = Self.service { _ in json(["id": "t1", "status": "completed", "words": [["text": "Hello.", "start": 500, "end": 1000]]]) }
        var backend = backend(stub)
        backend.chunkSeconds = 2

        let segments = try await backend.transcribe(try ws.track(seconds: 5, silentAt: [1.85, 3.85]), language: "en")

        #expect(stub.requests.filter { $0.url!.path.hasSuffix("/upload") }.count == 3)
        let offsets = segments.map { $0.start - 0.5 }
        #expect(offsets.count == 3 && offsets[0] == 0)
        #expect((1.84...1.96).contains(offsets[1]) && (3.84...3.96).contains(offsets[2]))
    }

    @Test func retriesServerErrorsWhilePolling() async throws {
        let stub = Self.service { $0 == 1 ? json([:], status: 503) : Self.completed }
        #expect(try await backend(stub).transcribe(try ws.track(seconds: 1), language: nil).count == 2)
        #expect(stub.requests.count == 4)
    }

    @Test func failedTranscriptRejectedKeyAndForeignUploadAddressFail() async throws {
        let audio = try ws.track(seconds: 1)
        let failed = Self.service { _ in json(["id": "t1", "status": "error", "error": "File does not appear to contain audio."]) }
        await #expect(throws: CloudError.failed(backend: "AssemblyAI", message: "File does not appear to contain audio.")) {
            try await self.backend(failed).transcribe(audio, language: nil)
        }
        let unauthorized = StubHTTP { _, _ in json(["error": "Authentication error, API token missing/invalid"], status: 401) }
        await #expect(throws: CloudError.invalidKey(backend: "AssemblyAI")) { try await self.backend(unauthorized).transcribe(audio, language: nil) }
        await #expect(throws: CloudError.invalidKey(backend: "AssemblyAI")) { try await self.backend(unauthorized, key: "").transcribe(audio, language: nil) }
        #expect(unauthorized.requests.count == 1)
        let foreign = Self.service(uploadHost: "evil.example")
        await #expect(throws: CloudError.badResponse(backend: "AssemblyAI")) { try await self.backend(foreign).transcribe(audio, language: nil) }
        #expect(foreign.requests.count == 1)
    }

    @Test func givesUpAfterMaxPolls() async throws {
        let stub = Self.service { _ in json(["id": "t1", "status": "processing"]) }
        var backend = backend(stub)
        backend.maxPolls = 4
        await #expect(throws: CloudError.failed(backend: "AssemblyAI", message: "timed out waiting for the transcript")) {
            try await backend.transcribe(try self.ws.track(seconds: 1), language: nil)
        }
        #expect(stub.requests.count == 6)
    }

    @Test func builtInMakersBuildAssemblyAIFromItsPreset() throws {
        let preset = try #require(Preset<TranscriptionBackendType>.all.first { $0.type == .assemblyAI })
        let setup = BackendSetup(type: preset.type, address: preset.address, model: preset.model, apiKey: "k", contextTokens: 0)
        #expect(BackendMakers.builtIn.transcription[.assemblyAI]?(setup).name == "assemblyai")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
