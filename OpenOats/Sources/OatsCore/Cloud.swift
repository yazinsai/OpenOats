import AVFoundation

/// Errors from cloud Transcription backends. Messages never include audio or transcript content.
public enum CloudError: LocalizedError, Equatable {
    case invalidKey(backend: String)
    case http(backend: String, status: Int, message: String?)
    case badResponse(backend: String)
    case badAddress(String)
    case failed(backend: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let backend): "\(backend) rejected the API key. Check Settings > AI."
        case .http(let backend, let status, let message): "\(backend) request failed (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        case .badResponse(let backend): "\(backend) returned a response OpenOats couldn't read."
        case .badAddress(let address): "\"\(address)\" isn't an http(s) address."
        case .failed(let backend, let message): "\(backend) couldn't transcribe the audio: \(message)"
        }
    }
}

/// Sends requests for a cloud backend, retrying 429, 5xx and dropped connections with exponential backoff.
public struct CloudClient: Sendable {
    public var backend: String
    public var session: URLSession
    public var attempts = 5
    public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(backend: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.backend = backend
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> Data {
        var delay = Duration.seconds(1)
        for attempt in 1... {
            let last = attempt >= attempts
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                if status == 401 || status == 403 { throw CloudError.invalidKey(backend: backend) }
                guard status == 429 || status >= 500, !last else {
                    throw CloudError.http(backend: backend, status: status, message: Self.message(in: data))
                }
                if let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
                    delay = .seconds(min(after, 60))
                }
            } catch let error as URLError where !last && Self.retriedNetworkErrors.contains(error.code) {}
            try await sleep(delay)
            delay *= 2
        }
        fatalError("unreachable")
    }

    /// Dropped or not-yet-available connections. The offline ones matter after sleep: a Meeting stopped by the lid
    /// closing is processed as the Mac wakes, often before Wi-Fi has rejoined, and the backoff (~15 s) covers that.
    static let retriedNetworkErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
    ]

    /// The API's own error message (`error.message`, `detail` or `message`), which describes the request, not the audio.
    static func message(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = json["error"] as? [String: Any]
        let text = error?["message"] as? String ?? json["error"] as? String ?? json["detail"] as? String ?? json["message"] as? String
        return text.map { String($0.prefix(200)) }
    }
}

/// A `multipart/form-data` request body.
public struct Multipart {
    public let boundary = "oats-\(UUID().uuidString)"
    public private(set) var body = Data()
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public init() {}

    public mutating func add(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func add(_ name: String, file: Data, filename: String, type: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n".utf8))
    }

    public func finished() -> Data { body + Data("--\(boundary)--\r\n".utf8) }
}

/// One compressed piece of a track for upload; `offset` is its start in seconds from the track start.
public struct AudioChunk: Sendable {
    public var url: URL
    public var offset: TimeInterval
}

extension TrackAudio {
    /// Writes the track as `.m4a` chunks of at most `maxSeconds` (AAC 32 kbps ≈ 14 MB/hour) into `directory`.
    /// Each cut lands on the quietest 10 ms in the chunk's last 5 s (or last tenth for short chunks) so words aren't split.
    public static func compressedChunks(of url: URL, maxSeconds: TimeInterval, in directory: URL) throws -> [AudioChunk] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let limit = Int(maxSeconds * sampleRate)
        let window = min(Int(5 * sampleRate), limit / 10)
        var chunks: [AudioChunk] = []
        var file: AVAudioFile?
        var written = 0, consumed = 0
        var pending: [Float] = []

        func write(_ count: Int) throws {
            guard count > 0 else { return }
            if file == nil {
                let chunk = AudioChunk(url: directory.appendingPathComponent("chunk-\(chunks.count).m4a"), offset: Double(consumed) / sampleRate)
                chunks.append(chunk)
                file = try AVAudioFile(forWriting: chunk.url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            pending.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            try file!.write(from: buffer)
            pending.removeFirst(count)
            written += count
            consumed += count
        }

        try forEachChunk(of: url) { buffer in
            pending.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            while written + pending.count > limit {
                try write(quietestCut(pending, from: limit - written - window, to: limit - written))
                file = nil
                written = 0
            }
            try write(max(0, min(pending.count, limit - window - written)))
        }
        try write(pending.count)
        return chunks
    }

    static func quietestCut(_ samples: [Float], from start: Int, to end: Int) -> Int {
        let frame = 160
        var best = end, bestEnergy = Float.infinity
        for i in stride(from: max(start, 0), through: end - frame, by: frame) {
            var energy: Float = 0
            for j in i..<i + frame { energy += samples[j] * samples[j] }
            if energy < bestEnergy { bestEnergy = energy; best = i + frame / 2 }
        }
        return max(best, 1)
    }
}
