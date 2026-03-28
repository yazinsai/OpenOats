import SwiftUI

struct MenuBarPopoverView: View {
    let coordinator: AppCoordinator
    let settings: AppSettings
    let onShowMainWindow: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

    private var recordingStartedAt: Date? {
        if case .recording(let metadata) = coordinator.state {
            return metadata.startedAt
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            primaryAction
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            Button(action: onShowMainWindow) {
                HStack {
                    Text(String(localized: "show_openoats"))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Button(action: onCheckForUpdates) {
                HStack {
                    Text(String(localized: "check_for_updates_1"))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Button(action: onQuit) {
                HStack {
                    Text(String(localized: "quit_openoats"))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 4)
        }
        .frame(width: 280)
        .onAppear {
            if coordinator.isRecording {
                startTimer()
            }
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if coordinator.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(String(localized: "recording_formattedtime"))
                    .font(.subheadline)
            } else if settings.meetingAutoDetectEnabled {
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                Text(String(localized: "listening_for_meetings"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(String(localized: "idle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if coordinator.isRecording {
            Button(action: {
                coordinator.handle(.userStopped, settings: settings)
            }
.accessibilityIdentifier("meeting_control_button")) {
                Text(String(localized: "stop_recording"))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.regular)
        } else {
            Button(action: {
                guard settings.hasAcknowledgedRecordingConsent else {
                    onShowMainWindow()
                    return
                }
                coordinator.handle(.userStarted(.manual()), settings: settings)
            }) {
                Text(String(localized: "start_recording"))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startTimer() {
        updateElapsed()
        stopTimer()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                updateElapsed()
            }
        }
    }

    private func updateElapsed() {
        if let start = recordingStartedAt {
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
        } else {
            elapsedSeconds = 0
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        elapsedSeconds = 0
    }
}
