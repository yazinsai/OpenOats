import SwiftUI

struct MenuBarPopoverView: View {
    let liveSessionController: LiveSessionController
    let meetingDetectionController: MeetingDetectionController
    let settings: SettingsStore
    let onShowMainWindow: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void

    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        let liveState = liveSessionController.state
        let detectionState = meetingDetectionController.state

        VStack(alignment: .leading, spacing: 0) {
            statusLine(liveState: liveState, detectionState: detectionState)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            primaryAction(liveState: liveState)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            Button(action: onShowMainWindow) {
                HStack {
                    Text("Show OpenOats")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Button(action: onCheckForUpdates) {
                HStack {
                    Text("Check for Updates…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Button(action: onQuit) {
                HStack {
                    Text("Quit OpenOats")
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
            updateTimer(for: liveState)
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: liveState.sessionPhase) { _, newPhase in
            updateTimer(for: newPhase)
        }
    }

    @ViewBuilder
    private func statusLine(
        liveState: LiveSessionController.State,
        detectionState: MeetingDetectionController.State
    ) -> some View {
        HStack(spacing: 6) {
            if liveState.isStartingSession {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
                    .font(.system(size: 13, weight: .medium))
            } else if liveState.isRunning {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording - \(formattedTime)")
                    .font(.system(size: 13, weight: .medium))
            } else if detectionState.isEnabled {
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                Text("Listening for meetings...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text("Idle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func primaryAction(liveState: LiveSessionController.State) -> some View {
        if liveState.isStartingSession {
            Button(action: {}) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting…")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(true)
        } else
        if liveState.isRunning {
            Button(action: {
                liveSessionController.stopSession()
            }) {
                Text("Stop Recording")
                    .font(.system(size: 13, weight: .medium))
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
                liveSessionController.startManualSession()
            }) {
                Text("Start Recording")
                    .font(.system(size: 13, weight: .medium))
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

    private func updateTimer(for phase: MeetingState) {
        if case .recording(let metadata) = phase {
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(metadata.startedAt)))
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func updateTimer(for state: LiveSessionController.State) {
        updateTimer(for: state.sessionPhase)
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                if let startedAt = liveSessionController.state.recordingStartedAt {
                    elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
                } else {
                    elapsedSeconds = 0
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        elapsedSeconds = 0
    }
}
