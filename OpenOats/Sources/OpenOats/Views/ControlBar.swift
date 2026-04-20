import SwiftUI

struct ControlBar: View {
    let isRunning: Bool
    let audioLevel: Float
    let isMicMuted: Bool
    let modelDisplayName: String
    let transcriptionPrompt: String
    let batchStatus: BatchAudioTranscriber.Status
    let batchIsImporting: Bool
    let kbIndexingStatus: KnowledgeBaseIndexingStatus
    let statusMessage: String?
    let errorMessage: String?
    let needsDownload: Bool
    let downloadProgress: Double?
    let downloadDetail: DownloadProgressDetail?
    let onToggle: () -> Void
    let onMuteToggle: () -> Void
    let onConfirmDownload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            // Download prompt
            if needsDownload && !isRunning {
                VStack(spacing: 6) {
                    Text(transcriptionPrompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Download Now") {
                        onConfirmDownload()
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle())
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if shouldShowStatusArea {
                VStack(alignment: .leading, spacing: 8) {
                    if batchStatus.isFooterVisible {
                        BatchActivityStatusView(status: batchStatus, isImporting: batchIsImporting)
                            .accessibilityIdentifier("app.controlBar.batchStatus")
                    }

                    if let status = statusMessage, status != "Ready" {
                        modelStatusSection(status: status)
                    }

                    if kbIndexingStatus.isVisible {
                        KnowledgeBaseStatusView(status: kbIndexingStatus)
                            .accessibilityIdentifier("app.controlBar.kbStatus")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            HStack(spacing: 10) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        if isRunning {
                            // Pulsing dot when live, static when muted
                            Circle()
                                .fill(isMicMuted ? Color.red : Color.green)
                                .frame(width: 8, height: 8)
                                .scaleEffect(isMicMuted ? 1.0 : 1.0 + CGFloat(audioLevel) * 0.5)
                                .animation(.easeOut(duration: 0.1), value: audioLevel)

                            Text(isMicMuted ? "Muted" : "Live")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isMicMuted ? .red : .primary)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)

                            Text("Start")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    // Avoid hover-driven local state here. On macOS 26 / Swift 6.2,
                    // switching this button from Start to Live while the pointer is
                    // over it can trip a SwiftUI executor crash in onHover handling.
                    .background(isRunning ? (isMicMuted ? Color.red.opacity(0.1) : Color.green.opacity(0.1)) : Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("app.controlBar.toggle")

                // Mute button + audio level bars when running
                if isRunning {
                    Button(action: onMuteToggle) {
                        Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isMicMuted ? .red : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(isMicMuted ? "Unmute microphone" : "Mute microphone")
                    .accessibilityIdentifier("app.controlBar.muteToggle")

                    AudioLevelView(level: audioLevel)
                        .frame(width: 40, height: 14)
                        .opacity(isMicMuted ? 0.3 : 1.0)
                }

                Spacer()

                Text(modelDisplayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("app.controlBar.model")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var shouldShowStatusArea: Bool {
        batchStatus.isFooterVisible
            || (statusMessage != nil && statusMessage != "Ready")
            || kbIndexingStatus.isVisible
    }

    @ViewBuilder
    private func modelStatusSection(status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if downloadProgress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.controlBar.status")
            }
            if let progress = downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("app.controlBar.downloadProgress")

                if let detail = downloadDetail {
                    HStack(spacing: 8) {
                        if let sizeText = detail.sizeText {
                            Text(sizeText)
                        }
                        if let speedText = detail.speedText {
                            Text(speedText)
                        }
                        if let etaText = detail.etaText {
                            Spacer()
                            Text(etaText)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private extension BatchAudioTranscriber.Status {
    var isFooterVisible: Bool {
        switch self {
        case .loading, .transcribing, .completed:
            return true
        case .idle, .cancelled, .failed:
            return false
        }
    }
}

/// Mini audio level visualizer — a few bars that react to mic input.
struct AudioLevelView: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = Float(i) / 5.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? Color.green.opacity(0.7) : Color.primary.opacity(0.08))
                    .frame(width: 3)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private struct KnowledgeBaseStatusView: View {
    let status: KnowledgeBaseIndexingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if case .scanning = status {
                    ProgressView()
                        .controlSize(.small)
                } else if case .embedding(let completed, _, _) = status, completed == 0 {
                    ProgressView()
                        .controlSize(.small)
                } else if case .completed = status {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                } else if case .failed = status {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if case .blocked = status {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(status.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(status.detailText ?? " ")
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(status.percentText ?? " ")
                    .opacity(status.percentText == nil ? 0 : 1)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .help(status.helpText)
    }
}

private struct BatchActivityStatusView: View {
    let status: BatchAudioTranscriber.Status
    let isImporting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch status {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                case .idle, .cancelled, .failed:
                    EmptyView()
                }

                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        }
    }

    private var title: String {
        switch status {
        case .loading:
            return isImporting ? "Preparing to import…" : "Loading batch model…"
        case .transcribing:
            return isImporting ? "Importing meeting recording…" : "Re-transcribing…"
        case .completed:
            return isImporting ? "Meeting recording imported" : "Re-transcription complete"
        case .idle, .cancelled, .failed:
            return ""
        }
    }

    private var progress: Double? {
        if case .transcribing(let value) = status {
            return value
        }
        return nil
    }

    private var trailingText: String? {
        guard let progress else { return nil }
        return "\(Int(progress * 100))%"
    }
}
