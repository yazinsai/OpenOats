import Foundation
import os

// MARK: - Cloud ASR shared error type

/// Errors for cloud-based ASR backends (AssemblyAI, ElevenLabs, etc.).
/// Response bodies are never included to avoid leaking sensitive data.
enum CloudASRError: LocalizedError {
    case invalidAPIKey(backend: String)
    case insufficientScope(backend: String, detail: String)
    case invalidUploadURL
    case httpError(statusCode: Int)
    case rateLimited(backend: String)
    case transcriptionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let backend):
            "Invalid \(backend) API key. Check Settings > Transcription."
        case .insufficientScope(let backend, let detail):
            "Your \(backend) plan doesn't include Speech-to-Text. \(detail)"
        case .invalidUploadURL:
            "Cloud ASR received an invalid upload URL."
        case .httpError(let code):
            "Cloud ASR request failed (HTTP \(code))."
        case .rateLimited(let backend):
            "\(backend) rate limited. Will retry automatically."
        case .transcriptionFailed(let msg):
            "Transcription failed: \(msg)"
        case .timeout:
            "Cloud ASR request timed out."
        }
    }
}

// MARK: - Retry helper for cloud backends

private let retryLog = Logger(subsystem: "com.openoats.app", category: "CloudRetry")

/// Retries `operation` on transient cloud errors (rate limiting, server errors)
/// with exponential backoff. Fails immediately on auth/client errors.
func withCloudRetry<T>(
    maxAttempts: Int = 3,
    initialDelay: Duration = .seconds(1),
    operation: () async throws -> T
) async throws -> T {
    var delay = initialDelay
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch let error as CloudASRError {
            let isLast = attempt == maxAttempts
            switch error {
            case .rateLimited:
                if isLast { throw error }
                retryLog.warning("Rate limited, retrying in \(delay) (attempt \(attempt)/\(maxAttempts))")
                try await Task.sleep(for: delay)
            case .httpError(let code) where code == 429 || code >= 500:
                if isLast { throw error }
                retryLog.warning("HTTP \(code), retrying in \(delay) (attempt \(attempt)/\(maxAttempts))")
                try await Task.sleep(for: delay)
            default:
                throw error
            }
            delay = delay * 2
        }
    }
    // Unreachable, but the compiler needs it.
    throw CloudASRError.transcriptionFailed("Retry loop exited unexpectedly.")
}
