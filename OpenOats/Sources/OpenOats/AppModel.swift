import AppKit
import OatsCapture
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
    /// Onboarding's status line for the background `oats download` of the on-device model.
    @Published private(set) var modelDownload: String?
    private var child: Process?

    /// Onboarding shows until the recording-consent acknowledgement is stored.
    var onboarded: Bool {
        get { settings.defaults.object(forKey: "v2.consentAcknowledged") != nil }
        set { settings.defaults.set(newValue ? Date() : nil, forKey: "v2.consentAcknowledged") }
    }

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
            let source = LiveCapture { problem in Task { @MainActor in Notifier.post("Recording problem", "\(problem)") } }
            recorder = try Recorder.start(store: store, source: source, language: settings.load().meetingLanguage,
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
        let process = Self.oatsChild("process", next.id)
        let input = Pipe()
        process.standardInput = input
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

    /// An `oats` child at background priority that exits with the app.
    private static func oatsChild(_ arguments: String...) -> Process {
        let process = Process()
        process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("oats")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["OATS_APP_CHILD": "1"]) { $1 }
        process.qualityOfService = .background
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Fetches the on-device model now, so the first Meeting doesn't wait for it.
    func downloadModel() {
        guard modelDownload == nil, settings.load().transcription.type == .onDevice else { return }
        let process = Self.oatsChild("download")
        process.terminationHandler = { process in
            let ok = process.terminationStatus == 0
            Task { @MainActor in
                AppModel.shared.modelDownload = ok ? "Transcription model ready." : "The transcription model will download with your first Meeting."
            }
        }
        modelDownload = "Downloading the transcription model in the background…"
        do { try process.run() } catch { modelDownload = nil }
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
