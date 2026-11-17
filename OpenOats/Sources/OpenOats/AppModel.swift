import AppKit
import OatsCapture
import OatsCore
import UniformTypeIdentifiers

/// Recording runs in-process; Processing runs through the shared `ProcessingQueue`, each Meeting in an
/// `oats process <id>` child at background priority, so CoreML memory never stays in the app.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct QueuedMeeting { var id: String, label: String }

    /// `OATS_MEETINGS_DIR` overrides the root (tests); the `oats` child inherits it.
    let store = ProcessInfo.processInfo.environment["OATS_MEETINGS_DIR"].map { MeetingStore(root: URL(fileURLWithPath: $0)) }
        ?? MeetingStore()
    let settings = SettingsStore()
    @Published private(set) var recorder: Recorder?
    @Published private(set) var startedAt: Date?
    @Published private(set) var queue: [QueuedMeeting] = []
    @Published private(set) var processingID: String?
    /// Free bytes once the Recorder warns about disk space, until the recording ends.
    @Published private(set) var lowDiskSpace: Int64?
    /// The Meeting selected in the window (a notification click selects its Meeting).
    @Published var selection: MeetingEntry.ID?
    /// Onboarding's status line for the background `oats download` of the on-device model.
    @Published private(set) var modelDownload: String?
    /// Calls in progress, oldest first, without ignored apps.
    @Published private(set) var calls: [CallApp] = []
    /// The Call a recording was started for; the recording stops when that Call ends.
    private var recordingCall: CallApp?
    private lazy var callWatcher: CallWatcher = CallWatcher { event in Task { @MainActor in AppModel.shared.handle(event) } }
    private lazy var processing: ProcessingQueue = ProcessingQueue(store: store) { folder in await AppModel.shared.runChild(folder) }
    private var child: Process?
    private var quitting = false

    var onboarded: Bool {
        get { settings.consentAcknowledged }
        set { settings.consentAcknowledged = newValue }
    }

    /// Migration, then recovery of Interrupted meetings, then the queue.
    func launch() {
        Migration.runIfNeeded(settings)
        for meeting in store.recoverInterruptedMeetings() {
            Notifier.post(meeting.message, "Its Meeting file will be marked as interrupted.", meeting: meeting.folder.id)
        }
        Task {
            await processing.resumePending()
            refreshQueue()
        }
        watchCalls()
    }

    /// Meeting detection follows its setting. Off in the UI smoke suite, whose fake capture has no Calls.
    func watchCalls() {
        if settings.load().askToRecordCalls, ProcessInfo.processInfo.environment["OATS_FAKE_CAPTURE"] != "1" {
            callWatcher.start()
        } else {
            callWatcher.stop()
            CallPrompt.withdraw(calls)
            calls = []
        }
    }

    /// Records a Call from its prompt or the menu, if it is still on.
    func record(_ call: CallApp) {
        guard calls.contains(call), recorder == nil else { return }
        start()
        if recorder != nil { recordingCall = call }
    }

    /// "Don't Ask for <app>": its Calls are left alone until Settings asks again.
    func ignore(_ call: CallApp) {
        if !SettingsModel.shared.settings.ignoredCallApps.contains(call.id) { SettingsModel.shared.settings.ignoredCallApps.append(call.id) }
        CallPrompt.withdraw([call])
        calls.removeAll { $0 == call }
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case let .started(call):
            guard !settings.load().ignoredCallApps.contains(call.id), !calls.contains(call) else { return }
            calls.append(call)
            // One prompt per Call, and none while recording: a Call that was recorded, or answered, isn't asked again.
            if recorder == nil { CallPrompt.post(call) }
        case let .ended(call):
            calls.removeAll { $0 == call }
            CallPrompt.withdraw([call])
            guard call == recordingCall, recorder != nil else { return }
            stop()
            Notifier.post("Recording stopped", "The \(call.name) call ended.")
        }
    }

    func toggleRecording() { recorder == nil ? start() : stop() }

    func start() {
        guard recorder == nil else { return }
        do {
            // `OATS_FAKE_CAPTURE=1` (UI smoke suite): a test tone instead of the mic and system audio.
            let source: any CaptureSource = ProcessInfo.processInfo.environment["OATS_FAKE_CAPTURE"] == "1" ? ToneSource()
                : LiveCapture { problem in Task { @MainActor in Notifier.post("Recording problem", "\(problem)") } }
            recorder = try Recorder.start(store: store, source: source, language: settings.load().meetingLanguage,
                                          onEvent: { event in Task { @MainActor in AppModel.shared.handle(event) } })
            startedAt = Date()
            CallPrompt.withdraw(calls)
        } catch {
            Notifier.post("Couldn't start recording", error.localizedDescription)
        }
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        startedAt = nil
        lowDiskSpace = nil
        recordingCall = nil
        do { try recorder.stop() } catch { Notifier.post("The recording didn't close cleanly", error.localizedDescription) }
        enqueue(recorder.folder)
    }

    /// Queues a Meeting (after Stop, Retry, re-process, import).
    func enqueue(_ folder: MeetingFolder) {
        Task {
            try? await processing.enqueue(folder)
            refreshQueue()
        }
    }

    /// Clears the checkpoints and queues the Meeting again, with the current Settings backends.
    func reprocess(_ entry: MeetingEntry) throws {
        guard let folder = entry.folder, !entry.isBusy else { return }
        try Processing.prepareReprocess(folder)
        enqueue(folder)
    }

    /// One audio file becomes a Meeting with a single mixed track, labelled `Speaker`, in the saved language.
    func importAudio(_ urls: [URL]) throws {
        guard urls.count == 1, let url = urls.first,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Drop a single audio file to import it."])
        }
        let folder = try store.importAudio([url], language: settings.load().meetingLanguage)
        enqueue(folder)
        selection = folder.id
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case let .lowDisk(free):
            lowDiskSpace = free
            Notifier.post("Low disk space", "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. Recording stops below 200 MB.")
        case let .stopped(folder, reason):
            if recorder?.folder == folder {
                recorder = nil
                startedAt = nil
                lowDiskSpace = nil
                recordingCall = nil
            }
            Notifier.post("Recording stopped", reason)
            enqueue(folder)
        }
    }

    private func refreshQueue() {
        queue = store.list().compactMap { folder in
            guard let status = try? folder.readStatus(), status.state == .processing else { return nil }
            return QueuedMeeting(id: folder.id, label: status.title ?? status.startedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// The queue's runner: an `oats process` child with the API keys on stdin. Returns when it exits.
    private func runChild(_ folder: MeetingFolder) async {
        let process = Self.oatsChild("process", folder.id)
        let input = Pipe()
        process.standardInput = input
        processingID = folder.id
        refreshQueue()
        var launchError: Error?
        await withCheckedContinuation { (exited: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in exited.resume() }
            do { try process.run() } catch {
                launchError = error
                return exited.resume()
            }
            child = process
            // Fails only if the child already exited; its meeting.json then says why.
            try? input.fileHandleForWriting.write(contentsOf: passedSecrets())
            try? input.fileHandleForWriting.close()
        }
        child = nil
        processingID = nil
        guard !quitting else { return }
        if let launchError { fail(folder, "Couldn't start Processing: \(launchError.localizedDescription)") } else { finished(folder) }
        refreshQueue()
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
        let status = try? folder.readStatus()
        switch status?.state {
        case .done:
            let name = status?.meetingFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
            Notifier.post("Meeting file ready", name, meeting: folder.id)
        case .needsAttention: Notifier.post("A Meeting needs attention", status?.lastError ?? "", meeting: folder.id)
        case .processing where !folder.isBusy: fail(folder, "Processing stopped unexpectedly.")
        default: break // deleted, or another OpenOats (the CLI) is processing it
        }
    }

    private func fail(_ folder: MeetingFolder, _ error: String) {
        _ = try? folder.updateStatus {
            $0.state = .needsAttention
            $0.lastError = error
        }
        Notifier.post("A Meeting needs attention", error, meeting: folder.id)
    }

    /// On quit; the Meeting stays `processing` and resumes on next launch.
    func stopProcessingChild() {
        quitting = true
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
