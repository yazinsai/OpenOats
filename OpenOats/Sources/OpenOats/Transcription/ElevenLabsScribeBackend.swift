import Foundation
import os

// MARK: - ElevenLabs Scribe Backend

/// Cloud transcription backend using the ElevenLabs Scribe v2 REST API.
/// @unchecked Sendable: session and prepared are written once in prepare() before any transcribe() calls.
final class ElevenLabsScribeBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "ElevenLabs Scribe"

    private let apiKey: String
    private let keyterms: [String]
    private let removeFillerWords: Bool
    private let session: URLSession
    private var prepared = false

    private static let log = Logger(subsystem: "com.openoats.app", category: "ElevenLabsScribe")

    // MARK: - Init

    init(apiKey: String, customVocabulary: String = "", removeFillerWords: Bool = false) {
        self.apiKey = apiKey
        self.keyterms = Self.parseKeyterms(customVocabulary)
        self.removeFillerWords = removeFillerWords
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

        // Validate using /v1/voices — universally accessible with any valid key,
        // unlike /v1/user which requires elevated account permissions.
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (_, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CloudASRError.invalidAPIKey(backend: "ElevenLabs")
            }
            if !(200 ..< 300).contains(http.statusCode) {
                throw CloudASRError.httpError(statusCode: http.statusCode)
            }
        }

        prepared = true
        Self.log.info("ElevenLabs Scribe backend prepared successfully")
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String? = nil
    ) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }

        // 1. Encode audio as WAV
        let wavData = WAVEncoder.encode(samples: samples)

        // 2. Build multipart/form-data body
        let boundary = UUID().uuidString
        let languageCode = locale.language.languageCode?.identifier ?? ""
        let body = Self.buildMultipartBody(
            boundary: boundary,
            wavData: wavData,
            languageCode: languageCode,
            keyterms: keyterms,
            removeFillerWords: removeFillerWords
        )

        // 3. POST to speech-to-text endpoint
        try Task.checkCancellation()

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let text: String = try await withTransientRetry { [session] in
            let (responseData, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw CloudASRError.invalidAPIKey(backend: "ElevenLabs")
                }
                if !(200 ..< 300).contains(http.statusCode) {
                    let errorBody = String(data: Data(responseData.prefix(2048)), encoding: .utf8) ?? "<non-utf8 body>"
                    Self.log.error("ElevenLabs Scribe request failed: status \(http.statusCode, privacy: .public), body: \(errorBody, privacy: .private)")
                    throw CloudASRError.httpError(statusCode: http.statusCode)
                }
            }

            let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            guard let text = json?["text"] as? String else {
                throw CloudASRError.transcriptionFailed("Missing text field in response.")
            }
            return text
        }

        Self.log.info("ElevenLabs Scribe transcription completed")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multipart Body Builder (internal for tests)

    /// Builds the multipart/form-data body posted to /v1/speech-to-text.
    ///
    /// `keyterms` are emitted as one multipart part per term, matching the
    /// ElevenLabs JS SDK and the Speech-to-Text API reference. Sending a single
    /// field with a JSON-array string as the value causes the server to validate
    /// the whole literal as one keyterm, which fails with
    /// `invalid_keyword` / "Some keyword contains invalid characters".
    static func buildMultipartBody(
        boundary: String,
        wavData: Data,
        languageCode: String,
        keyterms: [String],
        removeFillerWords: Bool
    ) -> Data {
        var body = Data()

        body.appendMultipart(boundary: boundary, name: "model_id", value: "scribe_v2")

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

        for keyterm in keyterms {
            body.appendMultipart(boundary: boundary, name: "keyterms", value: keyterm)
        }

        if removeFillerWords {
            body.appendMultipart(boundary: boundary, name: "no_verbatim", value: "true")
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
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

// MARK: - Multipart Form Data Helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n".data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
