import Foundation

struct StreamingTranscriptionSegment: Equatable, Sendable {
    let samples: [Float]
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(samples: [Float], startTime: TimeInterval, endTime: TimeInterval) {
        self.samples = samples
        self.startTime = startTime
        self.endTime = endTime
    }
}

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
    private let continuation: AsyncStream<StreamingTranscriptionSegment>.Continuation
    private let workerTask: Task<Void, Never>
    private let onProcessingChanged: (@Sendable (Bool) -> Void)?

    init(
        onProcessingChanged: (@Sendable (Bool) -> Void)? = nil,
        process: @escaping @Sendable (StreamingTranscriptionSegment) async -> Void
    ) {
        let (stream, continuation) = AsyncStream<StreamingTranscriptionSegment>.makeStream()
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

    func enqueue(_ segment: StreamingTranscriptionSegment) async {
        if let onProcessingChanged, await state.didEnqueue() {
            onProcessingChanged(true)
        }
        continuation.yield(segment)
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
