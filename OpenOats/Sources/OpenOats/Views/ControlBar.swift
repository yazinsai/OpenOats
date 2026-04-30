import SwiftUI

struct ControlBar: View {
    private enum BannerActionKind {
        case openSettings
        case openMicrophonePrivacySettings
    }

    private struct BannerAction {
        let title: String
        let kind: BannerActionKind
    }

    private struct BannerCopy {
        let title: String
        let detail: String?
        let action: BannerAction?
    }

    let isRunning: Bool
    let audioLevel: Float
    let recordingElapsedSeconds: Int
    let isMicMuted: Bool
    let isRecordingPaused: Bool
    let modelDisplayName: String
    let transcriptionPrompt: String
    let batchStatus: BatchAudioTranscriber.Status
    let batchIsImporting: Bool
    let kbIndexingStatus: KnowledgeBaseIndexingStatus
    let statusMessage: String?
    let errorMessage: String?
    let recordingHealthNotice: RecordingHealthNotice?
    let needsDownload: Bool
    let downloadProgress: Double?
    let downloadDetail: DownloadProgressDetail?
    let onToggle: () -> Void
    let onMuteToggle: () -> Void
    let onPauseToggle: () -> Void
    let onConfirmDownload: () -> Void
    let onOpenSettings: () -> Void
    let onOpenMicrophonePrivacySettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = errorMessage {
                statusBanner(
                    symbolName: "xmark.octagon.fill",
                    color: .red,
                    copy: errorBannerCopy(for: error)
                )
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

                    if let notice = recordingHealthNotice {
                        recordingHealthSection(notice: notice)
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
                if isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isRecordingPaused ? Color.orange : (isMicMuted ? Color.red : Color.green))
                            .frame(width: 8, height: 8)
                            .scaleEffect(isRecordingPaused || isMicMuted ? 1.0 : 1.0 + CGFloat(audioLevel) * 0.5)
                            .animation(.easeOut(duration: 0.1), value: audioLevel)

                        Text("\(isRecordingPaused ? "Paused" : (isMicMuted ? "Muted" : "Live")) \(ElapsedTimeFormatter.compactMinutesSeconds(recordingElapsedSeconds))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isRecordingPaused ? .orange : (isMicMuted ? .red : .primary))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isRecordingPaused ? Color.orange.opacity(0.1) : (isMicMuted ? Color.red.opacity(0.1) : Color.green.opacity(0.1)))
                    .clipShape(Capsule())
                    .accessibilityIdentifier("app.controlBar.status")

                    Button(action: onToggle) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle(color: .red))
                    .controlSize(.small)
                    .accessibilityIdentifier("app.controlBar.stop")
                } else {
                    Button(action: onToggle) {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)

                            Text("Start")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app.controlBar.toggle")
                }

                if isRunning {
                    Button(action: onPauseToggle) {
                        Image(systemName: isRecordingPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isRecordingPaused ? .orange : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(isRecordingPaused ? "Resume recording" : "Pause recording")
                    .accessibilityIdentifier("app.controlBar.pauseToggle")

                    Button(action: onMuteToggle) {
                        Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(isMicMuted ? .red : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(isMicMuted ? "Unmute microphone" : "Mute microphone")
                    .accessibilityIdentifier("app.controlBar.muteToggle")
                    .opacity(isRecordingPaused ? 0.3 : 1.0)
                    .disabled(isRecordingPaused)

                    AudioLevelView(level: audioLevel)
                        .frame(width: 40, height: 14)
                        .opacity(isRecordingPaused || isMicMuted ? 0.3 : 1.0)
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
            || recordingHealthNotice != nil
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

    @ViewBuilder
    private func recordingHealthSection(notice: RecordingHealthNotice) -> some View {
        let symbolName = switch notice.severity {
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
        let color = switch notice.severity {
        case .warning: Color.orange
        case .error: Color.red
        }
        statusBanner(
            symbolName: symbolName,
            color: color,
            copy: recordingHealthBannerCopy(for: notice.message)
        )
        .accessibilityIdentifier("app.controlBar.recordingHealth")
    }

    @ViewBuilder
    private func statusBanner(
        symbolName: String,
        color: Color,
        copy: BannerCopy
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: copy.detail == nil ? 0 : 2) {
                Text(copy.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let detail = copy.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let action = copy.action {
                Button(action.title) {
                    performBannerAction(action.kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    private func performBannerAction(_ action: BannerActionKind) {
        switch action {
        case .openSettings:
            onOpenSettings()
        case .openMicrophonePrivacySettings:
            onOpenMicrophonePrivacySettings()
        }
    }

    private func errorBannerCopy(for message: String) -> BannerCopy {
        switch message {
        case "The selected microphone is no longer available. Choose another microphone in Settings > Transcription.":
            BannerCopy(
                title: "Microphone unavailable",
                detail: "Choose another microphone in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "No default microphone is currently available.":
            BannerCopy(
                title: "No microphone",
                detail: "Connect or choose a microphone in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "The selected output device is no longer available. Choose another output device in Settings > Transcription.":
            BannerCopy(
                title: "Output device unavailable",
                detail: "Choose another output device in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "No system audio output device is currently available.":
            BannerCopy(
                title: "No output device",
                detail: "Connect or choose an output device in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "Failed to start system audio: No audio output device is currently available.":
            BannerCopy(
                title: "No output device",
                detail: "Connect or choose an output device in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case let message where message.contains("API key") && message.contains("Settings > Transcription"):
            BannerCopy(
                title: message.replacingOccurrences(of: ". Check Settings > Transcription.", with: ""),
                detail: "Update the cloud transcription key in Settings",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case let message where message.contains("Microphone access denied"),
             let message where message.contains("Microphone access is disabled"),
             let message where message.contains("Unable to verify microphone permission"):
            BannerCopy(
                title: "Microphone access disabled",
                detail: "Enable microphone access in System Settings",
                action: BannerAction(title: "Open System Settings", kind: .openMicrophonePrivacySettings)
            )
        default:
            BannerCopy(title: message, detail: nil, action: nil)
        }
    }

    private func recordingHealthBannerCopy(for message: String) -> BannerCopy {
        switch message {
        case "No microphone or system audio detected. Check your input and output device settings.":
            BannerCopy(
                title: "No audio detected",
                detail: "Check input and output devices",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "No system audio detected. Check the selected speaker/output device.":
            BannerCopy(
                title: "No system audio",
                detail: "Check output device",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "No microphone audio detected. Check the selected microphone.":
            BannerCopy(
                title: "No microphone audio",
                detail: "Check microphone",
                action: BannerAction(title: "Open Settings", kind: .openSettings)
            )
        case "Capturing audio, but live transcription is not producing text. Recovery batch transcription will run after you stop.":
            BannerCopy(title: "No live transcript yet", detail: "Recovery batch will run after stop", action: nil)
        case "Capturing audio, but live transcription is not producing text.":
            BannerCopy(title: "No live transcript yet", detail: nil, action: nil)
        default:
            BannerCopy(title: message, detail: nil, action: nil)
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
