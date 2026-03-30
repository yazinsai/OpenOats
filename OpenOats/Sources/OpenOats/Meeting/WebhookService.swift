import Foundation
import CryptoKit

/// Sends a POST request to a user-configured webhook URL when a meeting ends.
/// Uses only data that already exists at session finalization time.
enum WebhookService {
    struct Payload: Codable {
        let sessionID: String
        let startedAt: Date
        let endedAt: Date
        let title: String?
        let utteranceCount: Int
        let language: String?
        let meetingApp: String?
        let transcript: [TranscriptEntry]

        struct TranscriptEntry: Codable {
            let speaker: String
            let text: String
            let timestamp: Date
        }
    }

    /// Fire the webhook if configured. Runs detached so it never blocks finalization.
    @MainActor static func fireIfEnabled(
        settings: AppSettings,
        sessionIndex: SessionIndex,
        utterances: [Utterance]
    ) {
        guard settings.webhookEnabled,
              !settings.webhookURL.isEmpty,
              let url = URL(string: settings.webhookURL)
        else { return }

        let secret = settings.webhookSecret
        let payload = Payload(
            sessionID: sessionIndex.id,
            startedAt: sessionIndex.startedAt,
            endedAt: sessionIndex.endedAt ?? Date(),
            title: sessionIndex.title,
            utteranceCount: sessionIndex.utteranceCount,
            language: sessionIndex.language,
            meetingApp: sessionIndex.meetingApp,
            transcript: utterances.map { u in
                Payload.TranscriptEntry(
                    speaker: u.speaker.displayLabel,
                    text: u.cleanedText ?? u.text,
                    timestamp: u.timestamp
                )
            }
        )

        Task.detached {
            await send(payload: payload, to: url, secret: secret)
        }
    }

    // MARK: - Private

    private static func send(payload: Payload, to url: URL, secret: String) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let body = try? encoder.encode(payload) else {
            Log.webhook.error("Webhook: failed to encode payload")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !secret.isEmpty {
            let signature = hmacSHA256(data: body, key: secret)
            request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-OpenOats-Signature")
        }

        request.httpBody = body

        // Retry up to 3 times with exponential backoff (1s, 2s, 4s)
        for attempt in 0..<3 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    Log.webhook.info("Webhook delivered (attempt \(attempt + 1, privacy: .public), status \(http.statusCode, privacy: .public))")
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.webhook.warning("Webhook attempt \(attempt + 1, privacy: .public) returned status \(statusCode, privacy: .public)")
            } catch {
                Log.webhook.warning("Webhook attempt \(attempt + 1, privacy: .public) failed: \(error, privacy: .public)")
            }

            if attempt < 2 {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        Log.webhook.error("Webhook delivery failed after 3 attempts to \(url.absoluteString, privacy: .private)")
    }

    private static func hmacSHA256(data: Data, key: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}
