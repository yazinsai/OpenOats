import AppKit
import OatsCore

/// Recording runs in-process; Processing runs in an `oats process <id>` child at background priority, one Meeting at
/// a time, so CoreML memory never stays in the app. The queue is every Meeting whose `meeting.json` says `processing`.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct QueuedMeeting { var id: String, title: String }

    /// `OATS_MEETINGS_DIR` overrides the root (tests); the `oats` child inherits it.
    let store = ProcessInfo.processInfo.environment["OATS_MEETINGS_DIR"].map { MeetingStore(root: URL(fileURLWithPath: $0)) }
        ?? MeetingStore()
    let settings = SettingsStore()
    @Published private(set) var recorder: Recorder?
    @Published private(set) var startedAt: Date?
    @Published private(set) var queue: [QueuedMeeting] = []
    @Published private(set) var processingID: String?
    private var child: Process?

    /// Migration, then recovery of Interrupted meetings, then the queue.
    func launch() {
        Migration.runIfNeeded(settings)
        for meeting in store.recoverInterruptedMeetings() {
            Notifier.post(meeting.message, "Its Meeting file will be marked as interrupted.")
        }
        processNext()
    }

    func toggleRecording() { recorder == nil ? start() : stop() }

    func start() {
        guard recorder == nil else { return }
        do {
            recorder = try Recorder.start(store: store, source: LiveCapture { problem in
                Task { @MainActor in Notifier.post("Recording problem", "\(problem)") }
            }, language: settings.load().meetingLanguage,
                                      onEvent: { event in Task { @MainActor in AppModel.shared.handle(event) } })
            startedAt = Date()
        } catch {
            Notifier.post("Couldn't start recording", error.localizedDescription)
        }
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        startedAt = nil
        do { try recorder.stop() } catch { Notifier.post("The recording didn't close cleanly", error.localizedDescription) }
        processNext()
    }

    /// Queues a Meeting (Retry, re-process, import) and starts Processing if idle.
    func enqueue(_ folder: MeetingFolder) {
        _ = try? folder.updateStatus { $0.state = .processing }
        processNext()
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case let .lowDisk(free):
            Notifier.post("Low disk space", "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Recording stops below 200 MB.")
        case let .stopped(folder, reason):
            if recorder?.folder == folder {
                recorder = nil
                startedAt = nil
            }
            Notifier.post("Recording stopped", reason)
            processNext()
        }
    }

    /// Refreshes the queue and starts a child for its first Meeting unless one is running.
    private func processNext() {
        queue = store.list().compactMap { folder in
            guard let status = try? folder.readStatus(), status.state == .processing else { return nil }
            return QueuedMeeting(id: folder.id, title: status.startedAt.formatted(date: .abbreviated, time: .shortened))
        }
        guard child == nil, let next = queue.first.flatMap({ store.folder(id: $0.id) }) else { return }
        let process = Process()
        process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("oats")
        process.arguments = ["process", next.id]
        process.environment = ProcessInfo.processInfo.environment.merging(["OATS_APP_CHILD": "1"]) { $1 }
        process.qualityOfService = .background
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in Task { @MainActor in AppModel.shared.finished(next) } }
        do {
            try process.run()
        } catch {
            return fail(next, "Couldn't start Processing: \(error.localizedDescription)")
        }
        input.fileHandleForWriting.write(passedSecrets())
        try? input.fileHandleForWriting.close()
        child = process
        processingID = next.id
    }

    private func finished(_ folder: MeetingFolder) {
        child = nil
        processingID = nil
        let status = try? folder.readStatus()
        switch status?.state {
        case .done:
            let file = status?.meetingFile
            Notifier.post("Meeting file ready", file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "", file: file)
        case .needsAttention: Notifier.post("A Meeting needs attention", status?.lastError ?? "")
        case .processing: return fail(folder, "Processing stopped unexpectedly.")
        default: break
        }
        processNext()
    }

    private func fail(_ folder: MeetingFolder, _ error: String) {
        _ = try? folder.updateStatus {
            $0.state = .needsAttention
            $0.lastError = error
        }
        Notifier.post("A Meeting needs attention", error)
        processNext()
    }

    /// On quit; the Meeting stays `processing` and resumes on next launch.
    func stopProcessingChild() {
        child?.terminationHandler = nil
        child?.terminate()
    }

    /// The API keys of the saved backends, for the child's stdin.
    private func passedSecrets() -> Data {
        let s = settings.load()
        var keys: [String: String] = [:]
        keys[SettingsStore.keyAccount(for: s.transcription)] = settings.apiKey(for: s.transcription)
        keys[SettingsStore.keyAccount(for: s.notes)] = settings.apiKey(for: s.notes)
        return (try? JSONEncoder().encode(keys)) ?? Data("{}".utf8)
    }
}

/// Placeholder until real capture (#760, `OatsCapture.LiveCapture`, same initializer): silence on both tracks, in real time.
final class LiveCapture: CaptureSource, @unchecked Sendable {
    init(onProblem: @escaping @Sendable (String) -> Void) {}
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "openoats.capture"))

    func start(_ deliver: @escaping @Sendable (CapturedAudio) -> Void) throws {
        var sent = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            let silence = [Int16](repeating: 0, count: Int((now - sent) * TrackAudio.sampleRate))
            for track in Track.allCases { deliver(CapturedAudio(track: track, samples: silence, hostTime: sent)) }
            sent = now
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}
