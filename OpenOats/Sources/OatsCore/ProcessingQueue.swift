import Foundation

/// Persistent one-at-a-time Processing queue at background priority.
/// The queue is the set of Meetings whose `meeting.json` says `processing`, so it survives relaunch.
public actor ProcessingQueue {
    public let store: MeetingStore
    private let options: @Sendable () -> ProcessingOptions
    private var pending: [String] = []
    private var current: String?
    private var worker: Task<Void, Never>?
    private var onChange: (@Sendable ([String]) -> Void)?

    /// `options` is read when each Meeting starts, so settings changes apply to the next one.
    public init(store: MeetingStore, options: @escaping @Sendable () -> ProcessingOptions) {
        self.store = store
        self.options = options
    }

    /// Ids of the Meeting being processed (first) and those waiting.
    public var queued: [String] { (current.map { [$0] } ?? []) + pending }

    /// Called with `queued` whenever it changes (e.g. for the menu bar).
    public func observe(_ handler: @escaping @Sendable ([String]) -> Void) { onChange = handler }

    /// Queues every Meeting left in `processing` (call on launch, after Recorder recovery).
    public func resumePending() {
        for folder in store.list() where (try? folder.readStatus().state) == .processing {
            add(folder.id)
        }
    }

    /// Queues a Meeting: after Stop, for Retry, or after `Processing.prepareReprocess`.
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
        onChange?(queued)
        if worker == nil {
            worker = Task.detached(priority: .background) { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            current = pending.removeFirst()
            onChange?(queued)
            if let folder = store.folder(id: current!) {
                _ = try? await Processing.run(folder, options: options())
            }
            current = nil
            onChange?(queued)
        }
        worker = nil
    }
}
