import Foundation
import os

// MARK: - Cohere Transcribe Arabic Backend

/// Cloud transcription backend using Cohere's audio transcription REST API.
/// @unchecked Sendable: session and prepared are written once in prepare() before any transcribe() calls.
final class CohereTranscribeArabicBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Cohere Transcribe Arabic"

    private struct TranscriptionResponse: Decodable {
        struct Results: Decodable {
            struct Transcript: Decodable {
                let text: String
            }

            let transcripts: [Transcript]
        }

        let results: Results
    }

    private let apiKey: String
    private let promptTerms: [String]
    private let session: URLSession
    private var prepared = false

    private static let modelID = "cohere-transcribe-arabic-07-2026"
    private static let log = Logger(subsystem: "com.openoats.app", category: "CohereTranscribeArabic")

    // MARK: - Init

    init(apiKey: String, customVocabulary: String = "") {
        self.apiKey = apiKey
        self.promptTerms = Self.parsePromptTerms(customVocabulary)
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
            throw CloudASRError.invalidAPIKey(backend: "Cohere")
        }

        onStatus("Validating Cohere API key...")

        var request = URLRequest(url: URL(string: "https://api.cohere.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)
        try Self.checkHTTPStatus(response)

        prepared = true
        Self.log.info("Cohere Transcribe Arabic backend prepared successfully")
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String? = nil
    ) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }

        let wavData = WAVEncoder.encode(samples: samples)
        let boundary = UUID().uuidString
        let languageCode = Self.languageCode(for: locale)
        let prompt = Self.prompt(previousContext: previousContext, terms: promptTerms)
        let body = Self.buildMultipartBody(
            boundary: boundary,
            wavData: wavData,
            languageCode: languageCode,
            prompt: prompt
        )

        var request = URLRequest(url: URL(string: "https://api.cohere.com/v2/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let text: String = try await withTransientRetry { [session] in
            let (responseData, response) = try await session.data(for: request)
            try Self.checkHTTPStatus(response)
            return try Self.parseTranscriptResponse(responseData)
        }

        Self.log.info("Cohere Transcribe Arabic transcription completed")
        return text
    }

    // MARK: - Internal for tests

    static func buildMultipartBody(
        boundary: String,
        wavData: Data,
        languageCode: String,
        prompt: String?
    ) -> Data {
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "model", value: modelID)
        body.appendMultipart(boundary: boundary, name: "language", value: languageCode)

        if let prompt,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.appendMultipart(boundary: boundary, name: "prompt", value: prompt)
        }

        body.appendMultipart(
            boundary: boundary,
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: wavData
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    static func parseTranscriptResponse(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return response.results.transcripts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Private

    private static func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              !(200 ..< 300).contains(http.statusCode)
        else { return }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw CloudASRError.invalidAPIKey(backend: "Cohere")
        }
        throw CloudASRError.httpError(statusCode: http.statusCode)
    }

    private static func languageCode(for locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? ""
        return code.isEmpty ? "ar" : code
    }

    private static func prompt(previousContext: String?, terms: [String]) -> String? {
        var parts: [String] = []

        if let previousContext = previousContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previousContext.isEmpty {
            parts.append("Previous context: \(previousContext)")
        }

        if !terms.isEmpty {
            parts.append("Vocabulary: \(terms.joined(separator: ", "))")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func parsePromptTerms(_ vocabulary: String) -> [String] {
        let lines = vocabulary.split(separator: "\n", omittingEmptySubsequences: true)
        var result: [String] = []

        for line in lines {
            guard result.count < 100 else { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if let preferred = parts.first?.trimmingCharacters(in: .whitespaces),
                   !preferred.isEmpty {
                    result.append(preferred)
                }
            } else {
                result.append(trimmed)
            }
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
