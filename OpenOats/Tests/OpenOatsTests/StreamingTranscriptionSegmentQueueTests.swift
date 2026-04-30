import XCTest
@testable import OpenOatsKit

final class StreamingTranscriptionSegmentQueueTests: XCTestCase {
    func testQueueProcessesSegmentsInOrder() async {
        let recorder = SegmentQueueRecorder()
        let queue = StreamingTranscriptionSegmentQueue { segment in
            await recorder.record(segment)
            try? await Task.sleep(for: .milliseconds(10))
        }

        await queue.enqueue([1, 2])
        await queue.enqueue([3, 4])
        await queue.enqueue([5, 6])
        await queue.finish()

        let processed = await recorder.processedSegments
        XCTAssertEqual(processed, [[1, 2], [3, 4], [5, 6]])
    }

    func testQueueSignalsProcessingLifecycle() async {
        let stateRecorder = SegmentQueueStateRecorder()
        let expectation = XCTestExpectation(description: "processing lifecycle")
        expectation.expectedFulfillmentCount = 2
        let queue = StreamingTranscriptionSegmentQueue(
            onProcessingChanged: { isProcessing in
                Task {
                    await stateRecorder.record(isProcessing)
                    expectation.fulfill()
                }
            },
            process: { _ in
                try? await Task.sleep(for: .milliseconds(10))
            }
        )

        await queue.enqueue([1])
        await queue.enqueue([2])
        await queue.finish()
        await fulfillment(of: [expectation], timeout: 1.0)

        let recordedStates = await stateRecorder.states
        XCTAssertEqual(recordedStates, [true, false])
    }
}

private actor SegmentQueueRecorder {
    private(set) var processedSegments: [[Float]] = []

    func record(_ segment: [Float]) {
        processedSegments.append(segment)
    }
}

private actor SegmentQueueStateRecorder {
    private(set) var states: [Bool] = []

    func record(_ isProcessing: Bool) {
        states.append(isProcessing)
    }
}
