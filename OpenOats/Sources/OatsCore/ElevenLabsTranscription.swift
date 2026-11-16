import Foundation

/// The ElevenLabs Scribe Transcription backend. Uploads the track as m4a and groups the returned words into sentences.
/// A single mixed-file import is diarized, so its speakers come from Scribe.
public struct ElevenLabsTranscription: TranscriptionBackend {
    public static let defaultAddress = "https://api.elevenlabs.io/v1"
    public var address: String
    public var model: String
    public var apiKey: String?
    public var client: CloudClient
    /// Scribe takes files of several hours; one chunk keeps speaker labels consistent across a mixed import.
    public var chunkSeconds: TimeInterval = 3 * 3600

    public var name: String { "elevenlabs:\(model)" }
    public var separatesSpeakers: Bool { true }

    public init(address: String? = nil, model: String? = nil, apiKey: String?, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.address = address ?? Self.defaultAddress
        self.model = model ?? "scribe_v2"
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        client = CloudClient(backend: "ElevenLabs", session: session)
    }

    public init(_ setup: BackendSetup<TranscriptionBackendType>) {
        self.init(address: setup.address, model: setup.model, apiKey: setup.apiKey)
    }

    public func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { throw CloudError.badAddress(address) }
        guard let apiKey else { throw CloudError.invalidKey(backend: client.backend) }
        let diarize = audio.deletingPathExtension().lastPathComponent == "mixed"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oats-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var segments: [TimedSegment] = []
        for chunk in try TrackAudio.compressedChunks(of: audio, maxSeconds: chunkSeconds, in: directory) {
            var form = Multipart()
            form.add("model_id", model)
            if let language = language?.split(separator: "-").first { form.add("language_code", String(language)) }
            if diarize { form.add("diarize", "true") }
            form.add("file", file: try Data(contentsOf: chunk.url), filename: "audio.m4a", type: "audio/mp4")

            var request = URLRequest(url: url.appendingPathComponent("speech-to-text"), timeoutInterval: 900)
            request.httpMethod = "POST"
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.httpBody = form.finished()

            let data = try await client.send(request)
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw CloudError.badResponse(backend: client.backend) }
            let words = response.words.filter { $0.type == "word" }.map {
                Word(text: $0.text, start: chunk.offset + $0.start, end: chunk.offset + $0.end,
                     speaker: $0.speaker_id.map { "Speaker \((Int($0.split(separator: "_").last ?? "") ?? 0) + 1)" })
            }
            segments += Word.sentences(words)
        }
        return segments
    }

    private struct Response: Decodable {
        struct Word: Decodable { var text: String, start: Double, end: Double, type: String, speaker_id: String? }
        var words: [Word]
    }
}

/// A timed word from a cloud backend, seconds from the track start.
struct Word {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?

    /// Groups words into sentence segments, breaking on sentence-ending punctuation, a pause over 1 s or a speaker change.
    static func sentences(_ words: [Word]) -> [TimedSegment] {
        var segments: [TimedSegment] = []
        var open = false
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let punctuation = text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if open, let last = segments.last, punctuation || (last.speaker == word.speaker && word.start - last.end <= 1) {
                segments[segments.count - 1].text += punctuation ? text : " " + text
                segments[segments.count - 1].end = max(last.end, word.end)
            } else {
                segments.append(TimedSegment(start: word.start, end: word.end, text: text, speaker: word.speaker))
            }
            open = !".?!。？！".contains(text.last!)
        }
        return segments
    }
}
