import Foundation
import os

// MARK: - ElevenLabs Scribe Backend

/// Cloud transcription backend using the ElevenLabs Scribe v1 REST API.
/// @unchecked Sendable: session and prepared are written once in prepare() before any transcribe() calls.
final class ElevenLabsScribeBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "ElevenLabs Scribe"

    private let apiKey: String
    private let keyterms: [String]
    private let session: URLSession
    private var prepared = false

    private static let log = Logger(subsystem: "com.openoats.app", category: "ElevenLabsScribe")

    // MARK: - Init

    init(apiKey: String, customVocabulary: String = "") {
        self.apiKey = apiKey
        self.keyterms = Self.parseKeyterms(customVocabulary)
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - TranscriptionBackend

    func checkStatus() -> BackendStatus {
        .ready
    }

    func prepare(
        onStatus: @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw CloudASRError.invalidAPIKey(backend: "ElevenLabs")
        }

        onStatus("Validating ElevenLabs API key...")

        // POST a tiny silent WAV to the actual STT endpoint to prove the key
        // has Scribe/STT scope. A 200, 400, or 422 all confirm access.
        let silentWAV = WAVEncoder.encode(samples: [Float](repeating: 0, count: 1600))
        let boundary = UUID().uuidString
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "model_id", value: "scribe_v1")
        body.appendMultipart(
            boundary: boundary,
            name: "file",
            filename: "silence.wav",
            contentType: "audio/wav",
            data: silentWAV
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        let (_, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200, 400, 422:
                // Key has STT access (silent audio may produce empty/error result).
                break
            case 401, 403:
                throw CloudASRError.invalidAPIKey(backend: "ElevenLabs")
            case 429:
                throw CloudASRError.rateLimited(backend: "ElevenLabs")
            default:
                throw CloudASRError.httpError(statusCode: http.statusCode)
            }
        }

        prepared = true
        Self.log.info("ElevenLabs Scribe backend prepared successfully (STT validation)")
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String? = nil
    ) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }

        let wavData = WAVEncoder.encode(samples: samples)

        return try await withCloudRetry {
            // 1. Build multipart/form-data body
            let boundary = UUID().uuidString
            var body = Data()

            body.appendMultipart(boundary: boundary, name: "model_id", value: "scribe_v1")

            let languageCode = locale.language.languageCode?.identifier ?? ""
            if !languageCode.isEmpty {
                body.appendMultipart(boundary: boundary, name: "language_code", value: languageCode)
            }

            body.appendMultipart(
                boundary: boundary,
                name: "file",
                filename: "audio.wav",
                contentType: "audio/wav",
                data: wavData
            )

            if !self.keyterms.isEmpty {
                let jsonData = try JSONSerialization.data(withJSONObject: self.keyterms)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                body.appendMultipart(boundary: boundary, name: "keyterms", value: jsonString)
            }

            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            // 2. POST to speech-to-text endpoint
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
            request.httpMethod = "POST"
            request.setValue(self.apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 30

            let (responseData, response) = try await self.session.data(for: request)

            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 401, 403:
                    throw CloudASRError.invalidAPIKey(backend: "ElevenLabs")
                case 429:
                    throw CloudASRError.rateLimited(backend: "ElevenLabs")
                default:
                    throw CloudASRError.httpError(statusCode: http.statusCode)
                }
            }

            // 3. Parse JSON response
            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            guard let text = json?["text"] as? String else {
                throw CloudASRError.transcriptionFailed("Missing text field in response.")
            }

            Self.log.info("ElevenLabs Scribe transcription completed")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Private: Keyterms Parser

    /// Parses vocabulary lines into a flat array of keyterm strings.
    ///
    /// Input format (one entry per line):
    /// ```
    /// Preferred: alias1, alias2
    /// PlainTerm
    /// ```
    ///
    /// Lines with `:` use the preferred term (before the colon) only.
    /// Plain lines use the term as-is.
    /// Max 1000 terms; terms longer than 50 chars are truncated.
    private static func parseKeyterms(_ vocabulary: String) -> [String] {
        let lines = vocabulary.split(separator: "\n", omittingEmptySubsequences: true)
        var result: [String] = []

        for line in lines {
            guard result.count < 1000 else { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let term: String
            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count >= 1 else { continue }
                let preferred = parts[0].trimmingCharacters(in: .whitespaces)
                guard !preferred.isEmpty else { continue }
                term = preferred
            } else {
                term = trimmed
            }

            let finalTerm = term.count > 50 ? String(term.prefix(50)) : term
            result.append(finalTerm)
        }

        return result
    }
}

