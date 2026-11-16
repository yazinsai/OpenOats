import Foundation

/// Persistent one-at-a-time Processing queue at background priority, shared by the app and the CLI.
/// The queue is the set of Meetings whose `meeting.json` says `processing`, so it survives relaunch. Meetings another
/// process holds (recording or processing them) are skipped.
public actor ProcessingQueue {
    /// Processes one Meeting: in-process for the CLI, an `oats process` child for the app.
    public typealias Runner = @Sendable (MeetingFolder) async -> Void

    public let store: MeetingStore
    private let runner: Runner
    private var pending: [String] = []
    private var current: String?
    private var worker: Task<Void, Never>?

    public init(store: MeetingStore, runner: @escaping Runner) {
        self.store = store
        self.runner = runner
    }

    /// Runs Processing in this process. `options` is read when each Meeting starts, so settings changes apply to the next.
    public init(store: MeetingStore, options: @escaping @Sendable () -> ProcessingOptions) {
        self.init(store: store) { folder in _ = try? await Processing.run(folder, options: options()) }
    }

    /// Queues every Meeting left in `processing` (on launch, after `recoverInterruptedMeetings()`).
    public func resumePending() {
        for folder in store.list() where (try? folder.readStatus().state) == .processing { add(folder.id) }
    }

    /// Queues a Meeting: after Stop, for Retry, import, or after `Processing.prepareReprocess`.
    public func enqueue(_ folder: MeetingFolder) throws {
        try folder.updateStatus { $0.state = .processing }
        add(folder.id)
    }

    /// Waits until the queue is empty.
    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func add(_ id: String) {
        guard id != current, !pending.contains(id) else { return }
        pending.append(id)
        if worker == nil {
            worker = Task.detached(priority: .background) { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            current = id
            if let folder = store.folder(id: id), (try? folder.readStatus().state) == .processing, !folder.isBusy {
                await runner(folder)
            }
            current = nil
        }
        worker = nil
    }
}
