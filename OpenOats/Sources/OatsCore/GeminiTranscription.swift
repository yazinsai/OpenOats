import Foundation

/// The Gemini Transcription backend: `generateContent` with each m4a chunk inline, asking for JSON timed sentences.
/// Short chunks keep each reply well under the output-token limit and the 20 MB inline-request cap.
public struct GeminiTranscription: TranscriptionBackend {
    public static let defaultAddress = "https://generativelanguage.googleapis.com/v1beta"
    public var address: String
    public var model: String
    public var apiKey: String?
    public var client: CloudClient
    public var chunkSeconds: TimeInterval = 10 * 60

    public var name: String { "gemini:\(model)" }

    public init(address: String? = nil, model: String? = nil, apiKey: String?, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.address = address ?? Self.defaultAddress
        self.model = model ?? "gemini-3-flash-preview"
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        client = CloudClient(backend: "Gemini", session: session)
    }

    public init(_ setup: BackendSetup<TranscriptionBackendType>) {
        self.init(address: setup.address, model: setup.model, apiKey: setup.apiKey)
    }

    public func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { throw CloudError.badAddress(address) }
        guard let apiKey else { throw CloudError.invalidKey(backend: client.backend) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oats-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let prompt = "Transcribe this audio verbatim\(language.map { " (language: \($0))" } ?? ""). Return one JSON item per sentence, "
            + "with start and end as MM:SS.s timestamps from the start of the audio. Return [] if nobody speaks."
        let text = ["type": "STRING"]
        let schema: [String: Any] = ["type": "ARRAY", "items": ["type": "OBJECT", "properties": ["start": text, "end": text, "text": text],
                                                                  "required": ["start", "end", "text"]]]
        var segments: [TimedSegment] = []
        for chunk in try TrackAudio.compressedChunks(of: audio, maxSeconds: chunkSeconds, in: directory) {
            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt], ["inline_data": ["mime_type": "audio/mp4", "data": try Data(contentsOf: chunk.url).base64EncodedString()]]]]],
                "generationConfig": ["temperature": 0, "responseMimeType": "application/json", "responseSchema": schema],
            ]
            var request = URLRequest(url: url.appendingPathComponent("models/\(model):generateContent"), timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data = try await client.send(request)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let json = reply.candidates.first?.content?.parts.compactMap(\.text).joined(),
                  let items = try? JSONDecoder().decode([Reply.Item].self, from: Data(json.utf8))
            else { throw CloudError.badResponse(backend: client.backend) }
            let duration = TrackAudio.duration(of: chunk.url)
            for item in items {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = min(Self.seconds(item.start), duration)
                segments.append(TimedSegment(start: chunk.offset + start, end: chunk.offset + min(max(Self.seconds(item.end), start), duration), text: text))
            }
        }
        return segments
    }

    /// `HH:MM:SS.s`, `MM:SS.s` or plain seconds.
    static func seconds(_ timestamp: String) -> TimeInterval {
        timestamp.split(separator: ":").reduce(0) { $0 * 60 + (Double($1.trimmingCharacters(in: .whitespaces)) ?? 0) }
    }

    private struct Reply: Decodable {
        struct Candidate: Decodable { var content: Content? }
        struct Content: Decodable { var parts: [Part] }
        struct Part: Decodable { var text: String? }
        struct Item: Decodable { var start: String, end: String, text: String }
        var candidates: [Candidate]
    }
}
