import Foundation

/// The AssemblyAI Transcription backend: upload the m4a track, create a transcript, poll until it's done.
/// A single mixed-file import gets speaker labels. The speech model isn't pinned, so AssemblyAI picks its current one.
public struct AssemblyAITranscription: TranscriptionBackend {
    public static let defaultAddress = "https://api.assemblyai.com/v2"
    public var address: String
    public var apiKey: String?
    public var client: CloudClient
    public var chunkSeconds: TimeInterval = 3 * 3600
    public var pollInterval = Duration.seconds(3)
    /// About 30 minutes at the default interval.
    public var maxPolls = 600

    public var name: String { "assemblyai" }
    public var separatesSpeakers: Bool { true }

    public init(address: String? = nil, apiKey: String?, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.address = address ?? Self.defaultAddress
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        client = CloudClient(backend: "AssemblyAI", session: session)
    }

    public init(_ setup: BackendSetup<TranscriptionBackendType>) {
        self.init(address: setup.address, apiKey: setup.apiKey)
    }

    public func transcribe(_ audio: URL, language: String?) async throws -> [TimedSegment] {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { throw CloudError.badAddress(address) }
        guard apiKey != nil else { throw CloudError.invalidKey(backend: client.backend) }
        let diarize = audio.deletingPathExtension().lastPathComponent == Track.mixed.rawValue
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oats-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var segments: [TimedSegment] = []
        for chunk in try TrackAudio.compressedChunks(of: audio, maxSeconds: chunkSeconds, in: directory) {
            let upload: Upload = try await send(url.appendingPathComponent("upload"), body: try Data(contentsOf: chunk.url), type: "application/octet-stream")
            // The upload address goes back to AssemblyAI with the key, so only accept AssemblyAI's own hosts.
            guard let audioURL = URL(string: upload.upload_url), audioURL.scheme == "https",
                  let host = audioURL.host(), host == url.host() || host.hasSuffix(".assemblyai.com")
            else { throw CloudError.badResponse(backend: client.backend) }

            var job: [String: Any] = ["audio_url": audioURL.absoluteString, "speaker_labels": diarize]
            if let language = language?.split(separator: "-").first { job["language_code"] = String(language) } else { job["language_detection"] = true }
            var transcript: Transcript = try await send(url.appendingPathComponent("transcript"), body: try JSONSerialization.data(withJSONObject: job), type: "application/json")
            var polls = 0
            while transcript.status != "completed" {
                if transcript.status == "error" { throw CloudError.failed(backend: client.backend, message: transcript.error ?? "unknown error") }
                guard polls < maxPolls else { throw CloudError.failed(backend: client.backend, message: "timed out waiting for the transcript") }
                polls += 1
                try await client.sleep(pollInterval)
                transcript = try await send(url.appendingPathComponent("transcript/\(transcript.id)"))
            }
            segments += Word.sentences((transcript.words ?? []).map {
                Word(text: $0.text, start: chunk.offset + $0.start / 1000, end: chunk.offset + $0.end / 1000, speaker: $0.speaker.map { "Speaker \($0)" })
            })
        }
        return segments
    }

    private struct Upload: Decodable { var upload_url: String }
    private struct Transcript: Decodable {
        struct Word: Decodable { var text: String, start: Double, end: Double, speaker: String? }
        var id: String, status: String, error: String?, words: [Word]?
    }

    private func send<T: Decodable>(_ url: URL, body: Data? = nil, type: String? = nil) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await client.send(request)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw CloudError.badResponse(backend: client.backend) }
        return value
    }
}
