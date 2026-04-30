import Foundation

struct CloudTranscriptCopy {
    struct Presentation: Sendable, Equatable {
        let title: String
        let detail: String
    }

    static func steadyStateNotice(for model: TranscriptionModel) -> String? {
        guard model.isCloud else { return nil }
        let flushSeconds = model.flushIntervalSamples / 16_000
        return "Cloud transcript updates after pauses or about every \(flushSeconds)s of speech."
    }

    static func waitingMessage(for model: TranscriptionModel) -> String? {
        guard model.isCloud else { return nil }
        return "Waiting for transcript chunk…"
    }

    static let emptyChunk = Presentation(
        title: "Latest chunk returned no text",
        detail: "OpenOats is still listening for the next chunk."
    )

    static func presentation(for error: Error) -> Presentation {
        if let cloudError = error as? CloudASRError {
            switch cloudError {
            case .invalidAPIKey(let backend):
                return Presentation(
                    title: "\(backend) API key rejected",
                    detail: "Check Settings > Transcription."
                )
            case .httpError(let statusCode) where statusCode == 429:
                return Presentation(
                    title: "Cloud transcript is rate limited",
                    detail: "OpenOats will try again on the next chunk."
                )
            case .timeout:
                return Presentation(
                    title: "Cloud transcript timed out",
                    detail: "OpenOats is still listening for the next chunk."
                )
            case .httpError(let statusCode):
                return Presentation(
                    title: "Cloud transcript failed",
                    detail: "Request failed with HTTP \(statusCode)."
                )
            case .invalidUploadURL:
                return Presentation(
                    title: "Cloud transcript failed",
                    detail: "The cloud provider returned an invalid upload URL."
                )
            case .transcriptionFailed(let message):
                return Presentation(
                    title: "Cloud transcript failed",
                    detail: String(message.prefix(160))
                )
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return Presentation(
                    title: "Cloud transcript timed out",
                    detail: "OpenOats is still listening for the next chunk."
                )
            case .networkConnectionLost:
                return Presentation(
                    title: "Cloud connection dropped",
                    detail: "OpenOats will try again on the next chunk."
                )
            default:
                return Presentation(
                    title: "Cloud transcript failed",
                    detail: StreamingTranscriber.cloudDiagnosticsErrorMessage(for: error)
                )
            }
        }

        return Presentation(
            title: "Cloud transcript failed",
            detail: StreamingTranscriber.cloudDiagnosticsErrorMessage(for: error)
        )
    }
}
