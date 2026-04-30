import Foundation

/// Serializes asynchronous segment processing without blocking the capture loop.
final class StreamingTranscriptionSegmentQueue: @unchecked Sendable {
    private actor State {
        private var pendingCount = 0

        func didEnqueue() -> Bool {
            let becameActive = pendingCount == 0
            pendingCount += 1
            return becameActive
        }

        func didComplete() -> Bool {
            pendingCount = max(0, pendingCount - 1)
            return pendingCount == 0
        }

        func reset() {
            pendingCount = 0
        }
    }

    private let state = State()
    private let continuation: AsyncStream<[Float]>.Continuation
    private let workerTask: Task<Void, Never>
    private let onProcessingChanged: (@Sendable (Bool) -> Void)?

    init(
        onProcessingChanged: (@Sendable (Bool) -> Void)? = nil,
        process: @escaping @Sendable ([Float]) async -> Void
    ) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let state = self.state
        self.continuation = continuation
        self.onProcessingChanged = onProcessingChanged
        self.workerTask = Task {
            for await segment in stream {
                guard !Task.isCancelled else { break }
                await process(segment)
                if let onProcessingChanged, await state.didComplete() {
                    onProcessingChanged(false)
                }
            }
        }
    }

    func enqueue(_ samples: [Float]) async {
        if let onProcessingChanged, await state.didEnqueue() {
            onProcessingChanged(true)
        }
        continuation.yield(samples)
    }

    func finish() async {
        continuation.finish()
        await workerTask.value
    }

    func cancel() async {
        workerTask.cancel()
        continuation.finish()
        await workerTask.value
        await state.reset()
        onProcessingChanged?(false)
    }
}
