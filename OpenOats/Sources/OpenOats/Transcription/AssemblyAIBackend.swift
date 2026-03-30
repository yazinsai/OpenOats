import Foundation
import os

// MARK: - AssemblyAI Backend

/// Cloud transcription backend using the AssemblyAI REST API.
/// @unchecked Sendable: session and prepared are written once in prepare() before any transcribe() calls.
final class AssemblyAIBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "AssemblyAI"

    private let apiKey: String
    private let customSpelling: [[String: Any]]
    private let session: URLSession
    private var prepared = false

    private static let log = Logger(subsystem: "com.openoats.app", category: "AssemblyAI")

    // MARK: - Init

    init(apiKey: String, customVocabulary: String = "") {
        self.apiKey = apiKey
        self.customSpelling = Self.parseCustomSpelling(customVocabulary)
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
            throw CloudASRError.invalidAPIKey(backend: "AssemblyAI")
        }

        onStatus("Validating AssemblyAI API key...")

        // Upload a tiny silent WAV to prove write access without creating
        // a billable transcript.
        let silentWAV = WAVEncoder.encode(samples: [Float](repeating: 0, count: 1600))

        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = silentWAV

        let (responseData, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CloudASRError.invalidAPIKey(backend: "AssemblyAI")
            }
            if http.statusCode == 429 {
                throw CloudASRError.rateLimited(backend: "AssemblyAI")
            }
            if !(200 ..< 300).contains(http.statusCode) {
                throw CloudASRError.httpError(statusCode: http.statusCode)
            }
        }

        // Verify the response contains an upload_url to confirm write access.
        let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let urlString = json?["upload_url"] as? String, !urlString.isEmpty else {
            throw CloudASRError.transcriptionFailed("AssemblyAI upload validation failed: no upload_url in response.")
        }

        prepared = true
        Self.log.info("AssemblyAI backend prepared successfully (upload validation)")
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String? = nil
    ) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }

        let wavData = WAVEncoder.encode(samples: samples)

        return try await withCloudRetry {
            // 1. Upload audio
            let uploadURL = try await self.upload(wavData)

            // 2. Validate upload URL
            guard let components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false),
                  components.scheme == "https",
                  let host = components.host,
                  host.hasSuffix(".assemblyai.com")
            else {
                throw CloudASRError.invalidUploadURL
            }

            // 3. Create transcript
            let transcriptID = try await self.createTranscript(
                audioURL: uploadURL,
                locale: locale
            )

            // 4. Poll for completion
            let text = try await self.pollTranscript(id: transcriptID)

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Private: Upload

    private func upload(_ data: Data) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        try checkHTTPStatus(response)

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let urlString = json?["upload_url"] as? String,
              let url = URL(string: urlString)
        else {
            throw CloudASRError.invalidUploadURL
        }

        return url
    }

    // MARK: - Private: Create Transcript

    private func createTranscript(audioURL: URL, locale: Locale) async throws -> String {
        var body: [String: Any] = ["audio_url": audioURL.absoluteString]

        // Language code from locale (e.g. "en", "pl", "de")
        let languageCode = locale.language.languageCode?.identifier
        if let languageCode, !languageCode.isEmpty {
            body["language_code"] = languageCode
        }

        if !customSpelling.isEmpty {
            body["custom_spelling"] = customSpelling
        }

        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await session.data(for: request)
        try checkHTTPStatus(response)

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw CloudASRError.transcriptionFailed("Missing transcript ID in response.")
        }

        return id
    }

    // MARK: - Private: Poll

    private func pollTranscript(id: String) async throws -> String {
        let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        for _ in 0 ..< 60 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))

            let (data, response) = try await session.data(for: request)
            try checkHTTPStatus(response)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = json?["status"] as? String

            switch status {
            case "completed":
                let text = json?["text"] as? String ?? ""
                Self.log.info("Transcript \(id) completed")
                return text
            case "error":
                let errorMessage = json?["error"] as? String ?? "Unknown error"
                Self.log.error("Transcript \(id) failed: \(errorMessage)")
                throw CloudASRError.transcriptionFailed(errorMessage)
            default:
                continue
            }
        }

        Self.log.error("Transcript \(id) timed out after 30s")
        throw CloudASRError.timeout
    }

    // MARK: - Private: HTTP Status Check

    private func checkHTTPStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              !(200 ..< 300).contains(http.statusCode)
        else { return }
        switch http.statusCode {
        case 401, 403:
            throw CloudASRError.invalidAPIKey(backend: "AssemblyAI")
        case 429:
            throw CloudASRError.rateLimited(backend: "AssemblyAI")
        default:
            throw CloudASRError.httpError(statusCode: http.statusCode)
        }
    }

    // MARK: - Private: Custom Spelling Parser

    /// Parses vocabulary lines into AssemblyAI custom_spelling format.
    ///
    /// Input format (one entry per line):
    /// ```
    /// Preferred: alias1, alias2
    /// PlainTerm
    /// ```
    ///
    /// Lines with `:` produce `{"from": ["alias1", "alias2"], "to": "Preferred"}`.
    /// Lines without `:` are ignored (no alias mapping).
    private static func parseCustomSpelling(_ vocabulary: String) -> [[String: Any]] {
        vocabulary
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(":") else { return nil }

                let parts = trimmed.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }

                let preferred = parts[0].trimmingCharacters(in: .whitespaces)
                let aliases = parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                guard !preferred.isEmpty, !aliases.isEmpty else { return nil }

                return ["from": aliases, "to": preferred]
            }
    }
}
