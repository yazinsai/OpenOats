import Foundation

/// The OpenAI-style `/audio/transcriptions` Transcription backend (OpenAI, Groq, self-hosted Whisper servers).
/// Uploads the track as m4a chunks under the 25 MB cap and shifts each chunk's segments by its offset.
public struct OpenAIStyleTranscription: TranscriptionBackend {
    public static let defaultAddress = "https://api.openai.com/v1"
    public var address: String
    public var model: String
    public var apiKey: String?
    public var client: CloudClient
    /// Chunk length. `gpt-4o*` models return text without timings and stop at 25 min, so they get short chunks.
    public var chunkSeconds: TimeInterval

    public var name: String { "openai-style:\(model)" }
    var timed: Bool { !model.hasPrefix("gpt-") }

    public init(address: String? = nil, model: String? = nil, apiKey: String?, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.address = address ?? Self.defaultAddress
        self.model = model ?? "whisper-1"
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        client = CloudClient(backend: URL(string: self.address)?.host ?? "Transcription backend", session: session)
        chunkSeconds = self.model.hasPrefix("gpt-") ? 30 : 20 * 60
    }

    public init(_ setup: BackendSetup<TranscriptionBackendType>) {
        self.init(address: setup.address, model: setup.model, apiKey: setup.apiKey)
    }

    public func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { throw CloudError.badAddress(address) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oats-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var segments: [TimedSegment] = []
        for chunk in try TrackAudio.compressedChunks(of: audio, maxSeconds: chunkSeconds, in: directory) {
            let duration = TrackAudio.duration(of: chunk.url)
            for s in try await transcribe(chunk, to: url, language: language) {
                segments.append(TimedSegment(start: chunk.offset + (s.start ?? 0), end: chunk.offset + (s.end ?? duration), text: s.text))
            }
        }
        return segments
    }

    private struct Response: Decodable {
        struct Segment: Decodable { var start: Double?, end: Double?, text: String }
        var text: String
        var segments: [Segment]?
    }

    private func transcribe(_ chunk: AudioChunk, to address: URL, language: String?) async throws -> [Response.Segment] {
        var form = Multipart()
        form.add("model", model)
        if let language = language?.split(separator: "-").first { form.add("language", String(language)) }
        form.add("response_format", timed ? "verbose_json" : "json")
        if timed { form.add("timestamp_granularities[]", "segment") }
        form.add("file", file: try Data(contentsOf: chunk.url), filename: "audio.m4a", type: "audio/mp4")

        var request = URLRequest(url: address.appendingPathComponent("audio/transcriptions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = form.finished()

        let data = try await client.send(request)
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw CloudError.badResponse(backend: client.backend) }
        let segments = response.segments ?? [Response.Segment(start: nil, end: nil, text: response.text)]
        return segments.compactMap {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Response.Segment(start: $0.start, end: $0.end, text: text)
        }
    }
}
