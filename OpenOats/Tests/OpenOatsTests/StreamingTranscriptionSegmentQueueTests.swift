import XCTest
@testable import OpenOatsKit

final class StreamingTranscriptionSegmentQueueTests: XCTestCase {
    func testQueueProcessesSegmentsInOrder() async {
        let recorder = SegmentQueueRecorder()
        let queue = StreamingTranscriptionSegmentQueue { segment in
            await recorder.record(segment)
            try? await Task.sleep(for: .milliseconds(10))
        }

        await queue.enqueue(.init(samples: [1, 2], startTime: 0, endTime: 0.125))
        await queue.enqueue(.init(samples: [3, 4], startTime: 0.125, endTime: 0.25))
        await queue.enqueue(.init(samples: [5, 6], startTime: 0.25, endTime: 0.375))
        await queue.finish()

        let processed = await recorder.processedSegments
        XCTAssertEqual(processed.map(\.samples), [[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(processed.map(\.startTime), [0, 0.125, 0.25])
        XCTAssertEqual(processed.map(\.endTime), [0.125, 0.25, 0.375])
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

        await queue.enqueue(.init(samples: [1], startTime: 0, endTime: 1))
        await queue.enqueue(.init(samples: [2], startTime: 1, endTime: 2))
        await queue.finish()
        await fulfillment(of: [expectation], timeout: 1.0)

        let recordedStates = await stateRecorder.states
        XCTAssertEqual(recordedStates, [true, false])
    }
}

private actor SegmentQueueRecorder {
    private(set) var processedSegments: [StreamingTranscriptionSegment] = []

    func record(_ segment: StreamingTranscriptionSegment) {
        processedSegments.append(segment)
    }
}

private actor SegmentQueueStateRecorder {
    private(set) var states: [Bool] = []

    func record(_ isProcessing: Bool) {
        states.append(isProcessing)
    }
}
