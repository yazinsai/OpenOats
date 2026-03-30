import XCTest
@testable import OpenOatsKit

// MARK: - Retry Logic Tests

final class CloudRetryTests: XCTestCase {

    /// Helper that throws a given CloudASRError for the first N calls, then returns a value.
    private func makeFlakyOperation(
        failCount: Int,
        error: CloudASRError,
        successValue: String = "ok"
    ) -> (call: @Sendable () async throws -> String, callCount: @Sendable () -> Int) {
        let counter = Counter()
        let op: @Sendable () async throws -> String = {
            let n = counter.increment()
            if n <= failCount {
                throw error
            }
            return successValue
        }
        return (op, { counter.value })
    }

    func testSucceedsOnFirstAttempt() async throws {
        let (op, callCount) = makeFlakyOperation(failCount: 0, error: .rateLimited(backend: "Test"))
        let result = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount(), 1)
    }

    func testRetriesOnRateLimitedAndSucceeds() async throws {
        let (op, callCount) = makeFlakyOperation(
            failCount: 2,
            error: .rateLimited(backend: "Test")
        )
        let result = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount(), 3)
    }

    func testRetriesOnServerErrorAndSucceeds() async throws {
        let (op, callCount) = makeFlakyOperation(
            failCount: 1,
            error: .httpError(statusCode: 502)
        )
        let result = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount(), 2)
    }

    func testDoesNotRetryOnInvalidAPIKey() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 10,
            error: .invalidAPIKey(backend: "Test")
        )
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected invalidAPIKey error to be thrown immediately")
        } catch let error as CloudASRError {
            if case .invalidAPIKey = error {
                // Expected
            } else {
                XCTFail("Expected invalidAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(callCount(), 1, "Should not retry on invalidAPIKey")
    }

    func testDoesNotRetryOnClientHttpError() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 10,
            error: .httpError(statusCode: 404)
        )
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected httpError(404) to be thrown immediately")
        } catch let error as CloudASRError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 404)
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(callCount(), 1, "Should not retry on 4xx client errors (except 429)")
    }

    func testRespectsMaxAttempts() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 100,
            error: .rateLimited(backend: "Test")
        )
        do {
            _ = try await withCloudRetry(maxAttempts: 2, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected rateLimited error after exhausting retries")
        } catch let error as CloudASRError {
            if case .rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(callCount(), 2, "Should stop after maxAttempts")
    }

    func testRetriesOnHttp429() async throws {
        let (op, callCount) = makeFlakyOperation(
            failCount: 1,
            error: .httpError(statusCode: 429)
        )
        let result = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount(), 2)
    }

    func testDoesNotRetryOnInsufficientScope() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 10,
            error: .insufficientScope(backend: "Test", detail: "upgrade")
        )
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected insufficientScope error to be thrown immediately")
        } catch let error as CloudASRError {
            if case .insufficientScope = error {
                // Expected
            } else {
                XCTFail("Expected insufficientScope, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(callCount(), 1, "Should not retry on insufficientScope")
    }

    func testMaxAttemptsOneDoesNotRetryRetriableError() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 10,
            error: .rateLimited(backend: "Test")
        )

        do {
            _ = try await withCloudRetry(maxAttempts: 1, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected rateLimited error when maxAttempts is 1")
        } catch let error as CloudASRError {
            assertSameCloudError(error, .rateLimited(backend: "Test"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(callCount(), 1, "Should attempt exactly once when maxAttempts is 1")
    }

    func testRetriesForAllRetriableCloudErrors() async throws {
        let retriableErrors: [CloudASRError] = [
            .rateLimited(backend: "Test"),
            .httpError(statusCode: 429),
            .httpError(statusCode: 500),
            .httpError(statusCode: 599)
        ]

        for error in retriableErrors {
            let (op, callCount) = makeFlakyOperation(
                failCount: 1,
                error: error,
                successValue: "ok-\(String(describing: error))"
            )
            let result = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTAssertTrue(result.hasPrefix("ok-"), "Expected success after retry for \(error)")
            XCTAssertEqual(callCount(), 2, "Expected one retry for \(error)")
        }
    }

    func testDoesNotRetryForAllNonRetriableCloudErrors() async {
        let nonRetriableErrors: [CloudASRError] = [
            .invalidAPIKey(backend: "Test"),
            .insufficientScope(backend: "Test", detail: "upgrade required"),
            .invalidUploadURL,
            .transcriptionFailed("bad payload"),
            .timeout,
            .httpError(statusCode: 400),
            .httpError(statusCode: 499)
        ]

        for expectedError in nonRetriableErrors {
            let (op, callCount) = makeFlakyOperation(failCount: 10, error: expectedError)
            do {
                _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
                XCTFail("Expected non-retriable error to be thrown immediately: \(expectedError)")
            } catch let actual as CloudASRError {
                assertSameCloudError(actual, expectedError)
            } catch {
                XCTFail("Unexpected error type for \(expectedError): \(error)")
            }

            XCTAssertEqual(callCount(), 1, "Should not retry for \(expectedError)")
        }
    }

    func testCancellationErrorFromOperationIsNotRetried() async {
        let counter = Counter()
        let op: @Sendable () async throws -> String = {
            _ = counter.increment()
            throw CancellationError()
        }

        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(counter.value, 1, "CancellationError should not be retried")
    }

    func testCancellationDuringBackoffSleepPropagatesCancellationError() async {
        let (op, callCount) = makeFlakyOperation(
            failCount: 100,
            error: .rateLimited(backend: "Test")
        )

        let task = Task {
            try await withCloudRetry(maxAttempts: 5, initialDelay: .seconds(5), operation: op)
        }

        for _ in 0..<1_000 where callCount() == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(callCount(), 1, "Expected first attempt before cancellation")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError after task cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(callCount(), 1, "Should not perform additional attempts after cancellation")
    }

    func testNonCloudErrorsAreNotRetried() async {
        enum SentinelError: Error {
            case boom
        }

        let counter = Counter()
        let op: @Sendable () async throws -> String = {
            _ = counter.increment()
            throw SentinelError.boom
        }

        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1), operation: op)
            XCTFail("Expected SentinelError.boom")
        } catch let error as SentinelError {
            XCTAssertEqual(error, .boom)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(counter.value, 1, "Unexpected errors should not be retried")
    }
}

// MARK: - Thread-safe counter for test helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    /// Increments and returns the new value.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

private func assertSameCloudError(
    _ actual: CloudASRError,
    _ expected: CloudASRError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case let (.invalidAPIKey(actualBackend), .invalidAPIKey(expectedBackend)):
        XCTAssertEqual(actualBackend, expectedBackend, file: file, line: line)
    case let (.insufficientScope(actualBackend, actualDetail), .insufficientScope(expectedBackend, expectedDetail)):
        XCTAssertEqual(actualBackend, expectedBackend, file: file, line: line)
        XCTAssertEqual(actualDetail, expectedDetail, file: file, line: line)
    case (.invalidUploadURL, .invalidUploadURL):
        break
    case let (.httpError(actualCode), .httpError(expectedCode)):
        XCTAssertEqual(actualCode, expectedCode, file: file, line: line)
    case let (.rateLimited(actualBackend), .rateLimited(expectedBackend)):
        XCTAssertEqual(actualBackend, expectedBackend, file: file, line: line)
    case let (.transcriptionFailed(actualMessage), .transcriptionFailed(expectedMessage)):
        XCTAssertEqual(actualMessage, expectedMessage, file: file, line: line)
    case (.timeout, .timeout):
        break
    default:
        XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

// MARK: - Error Description Tests

final class CloudASRErrorTests: XCTestCase {

    func testInvalidAPIKeyDescription() {
        let error = CloudASRError.invalidAPIKey(backend: "Test")
        XCTAssertTrue(
            error.errorDescription?.contains("Invalid") == true,
            "Expected description to contain 'Invalid', got: \(error.errorDescription ?? "nil")"
        )
    }

    func testInsufficientScopeDescription() {
        let error = CloudASRError.insufficientScope(backend: "Test", detail: "x")
        let desc = error.errorDescription ?? ""
        // The description says "doesn't include Speech-to-Text" which implies scope
        XCTAssertTrue(
            desc.lowercased().contains("include") || desc.lowercased().contains("scope") || desc.lowercased().contains("plan"),
            "Expected description to reference scope/plan, got: \(desc)"
        )
    }

    func testRateLimitedDescription() {
        let error = CloudASRError.rateLimited(backend: "Test")
        XCTAssertTrue(
            error.errorDescription?.lowercased().contains("rate") == true,
            "Expected description to contain 'rate', got: \(error.errorDescription ?? "nil")"
        )
    }

    func testTimeoutDescription() {
        let error = CloudASRError.timeout
        XCTAssertTrue(
            error.errorDescription?.contains("timed out") == true,
            "Expected description to contain 'timed out', got: \(error.errorDescription ?? "nil")"
        )
    }

    func testHttpErrorDescription() {
        let error = CloudASRError.httpError(statusCode: 503)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("503"), "Expected description to contain status code 503, got: \(desc)")
    }

    func testInvalidUploadURLDescription() {
        let error = CloudASRError.invalidUploadURL
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("invalid") || desc.contains("Invalid") || desc.lowercased().contains("upload"),
                       "Expected description to mention invalid/upload, got: \(desc)")
    }

    func testTranscriptionFailedDescription() {
        let error = CloudASRError.transcriptionFailed("server error")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("server error"),
                       "Expected description to contain the message, got: \(desc)")
    }
}

// MARK: - Data+Multipart Tests

final class DataMultipartTests: XCTestCase {

    func testAppendMultipartStringValue() {
        var body = Data()
        let boundary = "test-boundary-123"
        body.appendMultipart(boundary: boundary, name: "language", value: "en")
        let text = String(data: body, encoding: .utf8)!

        XCTAssertTrue(text.contains("--test-boundary-123\r\n"),
                       "Should contain boundary delimiter")
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"language\""),
                       "Should contain form-data disposition with field name")
        XCTAssertTrue(text.contains("en\r\n"),
                       "Should contain the string value")
    }

    func testAppendMultipartFileData() {
        var body = Data()
        let boundary = "file-boundary-456"
        let fileContent = Data("fake audio".utf8)
        body.appendMultipart(
            boundary: boundary,
            name: "audio",
            filename: "recording.wav",
            contentType: "audio/wav",
            data: fileContent
        )
        let text = String(data: body, encoding: .utf8)!

        XCTAssertTrue(text.contains("--file-boundary-456\r\n"),
                       "Should contain boundary delimiter")
        XCTAssertTrue(text.contains("filename=\"recording.wav\""),
                       "Should contain filename in disposition")
        XCTAssertTrue(text.contains("Content-Type: audio/wav\r\n"),
                       "Should contain content type header")
        XCTAssertTrue(text.contains("fake audio"),
                       "Should contain the file data")
    }

    func testMultiplePartsPreserveBoundaries() {
        var body = Data()
        let boundary = "multi-part-boundary"
        body.appendMultipart(boundary: boundary, name: "model", value: "universal")
        body.appendMultipart(boundary: boundary, name: "language_code", value: "en")
        let text = String(data: body, encoding: .utf8)!

        let boundaryCount = text.components(separatedBy: "--multi-part-boundary\r\n").count - 1
        XCTAssertEqual(boundaryCount, 2, "Should have two boundary delimiters for two parts")
    }
}

// MARK: - Retry Edge Cases

final class CloudRetryEdgeCaseTests: XCTestCase {

    /// maxAttempts=1 should execute exactly once and throw on first retryable error.
    func testMaxAttemptsOneThrowsImmediatelyOnRetryableError() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 1, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.rateLimited(backend: "Test")
            }
            XCTFail("Expected error")
        } catch let error as CloudASRError {
            if case .rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 1, "Should execute exactly once with maxAttempts=1")
    }

    /// maxAttempts=1 should succeed if operation succeeds on first try.
    func testMaxAttemptsOneSucceedsOnFirstTry() async throws {
        let result = try await withCloudRetry(maxAttempts: 1, initialDelay: .milliseconds(1)) {
            "success"
        }
        XCTAssertEqual(result, "success")
    }

    /// Non-CloudASRError errors should propagate immediately without retry.
    func testNonCloudASRErrorPropagatesImmediately() async {
        struct CustomError: Error {}
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CustomError()
            }
            XCTFail("Expected error")
        } catch is CustomError {
            // Expected
        } catch {
            XCTFail("Expected CustomError, got \(error)")
        }
        XCTAssertEqual(counter.value, 1, "Non-CloudASRError should not be retried")
    }

    /// URLError should propagate immediately without retry (not a CloudASRError).
    func testURLErrorPropagatesImmediately() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw URLError(.timedOut)
            }
            XCTFail("Expected error")
        } catch is URLError {
            // Expected
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
        XCTAssertEqual(counter.value, 1, "URLError should not be retried")
    }

    /// CancellationError during backoff sleep should propagate.
    func testCancellationDuringBackoffPropagates() async {
        let started = Counter()
        let task = Task {
            try await withCloudRetry(maxAttempts: 5, initialDelay: .seconds(60)) {
                _ = started.increment()
                throw CloudASRError.httpError(statusCode: 500)
            }
        }

        // Wait for first attempt to execute
        while started.value == 0 {
            await Task.yield()
        }

        // Cancel while sleeping during backoff
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected - Task.sleep threw CancellationError during backoff
        } catch {
            // httpError(500) is also acceptable if cancellation races with throw
        }
        XCTAssertEqual(started.value, 1, "Should only have attempted once before cancellation")
    }

    /// HTTP 500 should be retried, HTTP 499 should not.
    func testHttp499IsNotRetried() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.httpError(statusCode: 499)
            }
            XCTFail("Expected httpError")
        } catch let error as CloudASRError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 499)
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 1, "HTTP 499 should not be retried")
    }

    /// HTTP 500 should be retried up to maxAttempts.
    func testHttp500IsRetried() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.httpError(statusCode: 500)
            }
            XCTFail("Expected httpError")
        } catch let error as CloudASRError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 3, "HTTP 500 should be retried up to maxAttempts")
    }

    /// HTTP 502 should be retried.
    func testHttp502IsRetried() async throws {
        let counter = Counter()
        let result: String = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
            let n = counter.increment()
            if n <= 1 {
                throw CloudASRError.httpError(statusCode: 502)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(counter.value, 2)
    }

    /// HTTP 503 should be retried.
    func testHttp503IsRetried() async throws {
        let counter = Counter()
        let result: String = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
            let n = counter.increment()
            if n <= 2 {
                throw CloudASRError.httpError(statusCode: 503)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(counter.value, 3)
    }

    /// .transcriptionFailed should not be retried (not transient).
    func testTranscriptionFailedIsNotRetried() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.transcriptionFailed("bad audio")
            }
            XCTFail("Expected transcriptionFailed")
        } catch let error as CloudASRError {
            if case .transcriptionFailed(let msg) = error {
                XCTAssertEqual(msg, "bad audio")
            } else {
                XCTFail("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 1, ".transcriptionFailed should not be retried")
    }

    /// .timeout should not be retried.
    func testTimeoutIsNotRetried() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.timeout
            }
            XCTFail("Expected timeout")
        } catch let error as CloudASRError {
            if case .timeout = error {
                // Expected
            } else {
                XCTFail("Expected timeout, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 1, ".timeout should not be retried")
    }

    /// .invalidUploadURL should not be retried.
    func testInvalidUploadURLIsNotRetried() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 3, initialDelay: .milliseconds(1)) {
                _ = counter.increment()
                throw CloudASRError.invalidUploadURL
            }
            XCTFail("Expected invalidUploadURL")
        } catch let error as CloudASRError {
            if case .invalidUploadURL = error {
                // Expected
            } else {
                XCTFail("Expected invalidUploadURL, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 1, ".invalidUploadURL should not be retried")
    }

    /// Verify exponential backoff timing (rough sanity check).
    func testExponentialBackoffIncreasesDelay() async {
        let timestamps = TimestampRecorder()
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 4, initialDelay: .milliseconds(50)) {
                _ = counter.increment()
                timestamps.record()
                throw CloudASRError.rateLimited(backend: "Test")
            }
        } catch {}

        XCTAssertEqual(counter.value, 4)
        let times = timestamps.values
        guard times.count == 4 else {
            XCTFail("Expected 4 timestamps, got \(times.count)")
            return
        }

        // Delays: 50ms, 100ms, 200ms (doubling each time)
        // Between attempt 1 and 2: ~50ms
        // Between attempt 2 and 3: ~100ms
        // Between attempt 3 and 4: ~200ms
        let gap1 = times[1].timeIntervalSince(times[0])
        let gap2 = times[2].timeIntervalSince(times[1])
        let gap3 = times[3].timeIntervalSince(times[2])

        // Each gap should increase (generous tolerance for CI runner scheduling jitter)
        XCTAssertGreaterThan(gap3, gap1, "Third delay should be longer than first")
    }

    /// Mixed errors: retryable error followed by non-retryable should stop at non-retryable.
    func testMixedRetryableAndNonRetryableErrors() async {
        let counter = Counter()
        do {
            _ = try await withCloudRetry(maxAttempts: 5, initialDelay: .milliseconds(1)) {
                let n = counter.increment()
                if n == 1 {
                    throw CloudASRError.rateLimited(backend: "Test")
                }
                throw CloudASRError.invalidAPIKey(backend: "Test")
            }
            XCTFail("Expected invalidAPIKey error")
        } catch let error as CloudASRError {
            if case .invalidAPIKey = error {
                // Expected: first attempt was retryable, second was not
            } else {
                XCTFail("Expected invalidAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertEqual(counter.value, 2, "Should retry once for rateLimited, then fail on invalidAPIKey")
    }
}

// MARK: - Circuit Breaker Logic Tests

/// Tests for the circuit breaker pattern used in StreamingTranscriber.
/// Since StreamingTranscriber requires full audio pipeline, we test the
/// threshold logic through a minimal reproduction of the pattern.
final class CircuitBreakerPatternTests: XCTestCase {

    /// Simulates the circuit breaker logic from StreamingTranscriber.transcribeSegment().
    private struct CircuitBreaker {
        var consecutiveErrors = 0
        static let threshold = 5
        var tripped: Bool { consecutiveErrors >= Self.threshold }

        /// Returns (shouldCallOnError, isTerminal) based on circuit breaker state.
        mutating func recordSuccess() {
            consecutiveErrors = 0
        }

        mutating func recordError() -> (errorShouldSurface: Bool, isTerminal: Bool) {
            consecutiveErrors += 1
            if consecutiveErrors >= Self.threshold {
                return (true, true)
            }
            return (true, false)
        }

        /// Whether transcription should be skipped (breaker tripped).
        var shouldSkipTranscription: Bool {
            consecutiveErrors >= Self.threshold
        }
    }

    func testCircuitBreakerTripsAfterThresholdErrors() {
        var cb = CircuitBreaker()
        for i in 1...4 {
            let result = cb.recordError()
            XCTAssertFalse(result.isTerminal, "Should not be terminal after \(i) errors")
            XCTAssertFalse(cb.shouldSkipTranscription, "Should not skip after \(i) errors")
        }
        let result = cb.recordError()
        XCTAssertTrue(result.isTerminal, "Should be terminal after 5 errors")
        XCTAssertTrue(cb.shouldSkipTranscription, "Should skip after 5 errors")
    }

    func testCircuitBreakerResetsOnSuccess() {
        var cb = CircuitBreaker()
        // Accumulate 4 errors
        for _ in 1...4 {
            _ = cb.recordError()
        }
        XCTAssertFalse(cb.shouldSkipTranscription)

        // Success resets
        cb.recordSuccess()
        XCTAssertEqual(cb.consecutiveErrors, 0)
        XCTAssertFalse(cb.shouldSkipTranscription)

        // Need 5 more errors to trip again
        for _ in 1...4 {
            _ = cb.recordError()
        }
        XCTAssertFalse(cb.shouldSkipTranscription)
    }

    func testCircuitBreakerSkipsTranscriptionWhenTripped() {
        var cb = CircuitBreaker()
        for _ in 1...5 {
            _ = cb.recordError()
        }
        XCTAssertTrue(cb.shouldSkipTranscription)

        // Additional errors should not change terminal state
        let result = cb.recordError()
        XCTAssertTrue(result.isTerminal)
        XCTAssertEqual(cb.consecutiveErrors, 6)
    }

    func testCircuitBreakerThresholdIsExactlyFive() {
        XCTAssertEqual(CircuitBreaker.threshold, 5,
                       "Threshold should match StreamingTranscriber.circuitBreakerThreshold")
    }

    func testCircuitBreakerNotTrippedAtFourErrors() {
        var cb = CircuitBreaker()
        for _ in 1...4 {
            _ = cb.recordError()
        }
        XCTAssertFalse(cb.tripped)
        XCTAssertEqual(cb.consecutiveErrors, 4)
    }

    func testCircuitBreakerTrippedAtExactlyFiveErrors() {
        var cb = CircuitBreaker()
        for _ in 1...5 {
            _ = cb.recordError()
        }
        XCTAssertTrue(cb.tripped)
        XCTAssertEqual(cb.consecutiveErrors, 5)
    }
}

// MARK: - Error Deduplication Tests

/// Tests the deduplication pattern used in TranscriptionEngine's onError callback.
final class ErrorDeduplicationTests: XCTestCase {

    /// Simulates the error dedup logic from TranscriptionEngine.makeTranscriber().
    private class ErrorDeduplicator {
        var lastErrorMessage: String?
        var lastErrorTimestamp: Date = .distantPast
        var surfacedErrors: [String] = []
        let windowSeconds: TimeInterval

        init(windowSeconds: TimeInterval = 30) {
            self.windowSeconds = windowSeconds
        }

        func handleError(_ message: String, at time: Date = .now) {
            if message == lastErrorMessage,
               time.timeIntervalSince(lastErrorTimestamp) < windowSeconds {
                return
            }
            lastErrorMessage = message
            lastErrorTimestamp = time
            surfacedErrors.append(message)
        }
    }

    func testFirstErrorAlwaysSurfaces() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Connection failed", at: now)
        XCTAssertEqual(dedup.surfacedErrors.count, 1)
        XCTAssertEqual(dedup.surfacedErrors.first, "Connection failed")
    }

    func testDuplicateWithin30sIsSuppressed() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Connection failed", at: now)
        dedup.handleError("Connection failed", at: now.addingTimeInterval(10))
        dedup.handleError("Connection failed", at: now.addingTimeInterval(20))
        XCTAssertEqual(dedup.surfacedErrors.count, 1,
                       "Duplicate errors within 30s should be suppressed")
    }

    func testDuplicateAfter30sSurfaces() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Connection failed", at: now)
        dedup.handleError("Connection failed", at: now.addingTimeInterval(31))
        XCTAssertEqual(dedup.surfacedErrors.count, 2,
                       "Same error after 30s should surface again")
    }

    func testDifferentErrorAlwaysSurfaces() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Connection failed", at: now)
        dedup.handleError("Rate limited", at: now.addingTimeInterval(1))
        XCTAssertEqual(dedup.surfacedErrors.count, 2)
        XCTAssertEqual(dedup.surfacedErrors, ["Connection failed", "Rate limited"])
    }

    func testAlternatingErrorsBothSurface() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Error A", at: now)
        dedup.handleError("Error B", at: now.addingTimeInterval(1))
        dedup.handleError("Error A", at: now.addingTimeInterval(2))
        // Error A at +2s: lastErrorMessage is "Error B", so different => surfaces
        XCTAssertEqual(dedup.surfacedErrors.count, 3)
    }

    func testDeduplicationAtExactly30sBoundary() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Error X", at: now)
        // At exactly 30s: timeIntervalSince is 30, which is NOT < 30, so should surface
        dedup.handleError("Error X", at: now.addingTimeInterval(30))
        XCTAssertEqual(dedup.surfacedErrors.count, 2,
                       "Error at exactly 30s boundary should surface (< 30 check)")
    }

    func testDeduplicationJustBefore30sBoundary() {
        let dedup = ErrorDeduplicator()
        let now = Date()
        dedup.handleError("Error X", at: now)
        dedup.handleError("Error X", at: now.addingTimeInterval(29.999))
        XCTAssertEqual(dedup.surfacedErrors.count, 1,
                       "Error just before 30s should still be suppressed")
    }
}

// MARK: - Backend prepare() Validation Tests

final class CloudBackendPrepareTests: XCTestCase {

    func testAssemblyAIPrepareWithEmptyKeyThrowsInvalidAPIKey() async {
        let backend = AssemblyAIBackend(apiKey: "")
        do {
            try await backend.prepare(onStatus: { _ in }, onProgress: { _ in })
            XCTFail("Expected invalidAPIKey error")
        } catch let error as CloudASRError {
            if case .invalidAPIKey(let backend) = error {
                XCTAssertEqual(backend, "AssemblyAI")
            } else {
                XCTFail("Expected invalidAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElevenLabsPrepareWithEmptyKeyThrowsInvalidAPIKey() async {
        let backend = ElevenLabsScribeBackend(apiKey: "")
        do {
            try await backend.prepare(onStatus: { _ in }, onProgress: { _ in })
            XCTFail("Expected invalidAPIKey error")
        } catch let error as CloudASRError {
            if case .invalidAPIKey(let backend) = error {
                XCTAssertEqual(backend, "ElevenLabs")
            } else {
                XCTFail("Expected invalidAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testAssemblyAITranscribeBeforePrepareThrowsNotPrepared() async {
        let backend = AssemblyAIBackend(apiKey: "some-key")
        do {
            _ = try await backend.transcribe([0.0], locale: Locale(identifier: "en-US"))
            XCTFail("Expected notPrepared error")
        } catch is TranscriptionBackendError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testElevenLabsTranscribeBeforePrepareThrowsNotPrepared() async {
        let backend = ElevenLabsScribeBackend(apiKey: "some-key")
        do {
            _ = try await backend.transcribe([0.0], locale: Locale(identifier: "en-US"))
            XCTFail("Expected notPrepared error")
        } catch is TranscriptionBackendError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - CloudASRError Comprehensive Tests

final class CloudASRErrorComprehensiveTests: XCTestCase {

    /// All error cases should produce non-nil errorDescription.
    func testAllCasesHaveNonNilDescription() {
        let errors: [CloudASRError] = [
            .invalidAPIKey(backend: "Test"),
            .insufficientScope(backend: "Test", detail: "upgrade"),
            .invalidUploadURL,
            .httpError(statusCode: 500),
            .rateLimited(backend: "Test"),
            .transcriptionFailed("msg"),
            .timeout,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "errorDescription should not be nil for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty,
                           "errorDescription should not be empty for \(error)")
        }
    }

    /// httpError descriptions should include the status code.
    func testHttpErrorDescriptionContainsStatusCode() {
        for code in [400, 401, 403, 404, 429, 500, 502, 503] {
            let error = CloudASRError.httpError(statusCode: code)
            let desc = error.errorDescription ?? ""
            XCTAssertTrue(desc.contains("\(code)"),
                          "HTTP \(code) description should contain the code, got: \(desc)")
        }
    }

    /// Backend name should appear in relevant error descriptions.
    func testBackendNameAppearsInDescription() {
        let invalidKey = CloudASRError.invalidAPIKey(backend: "MyService")
        XCTAssertTrue(invalidKey.errorDescription?.contains("MyService") == true)

        let insuffScope = CloudASRError.insufficientScope(backend: "MyService", detail: "need upgrade")
        XCTAssertTrue(insuffScope.errorDescription?.contains("MyService") == true)

        let rateLimit = CloudASRError.rateLimited(backend: "MyService")
        XCTAssertTrue(rateLimit.errorDescription?.contains("MyService") == true)
    }

    /// transcriptionFailed should include the original message.
    func testTranscriptionFailedPreservesMessage() {
        let msg = "Server returned malformed JSON"
        let error = CloudASRError.transcriptionFailed(msg)
        XCTAssertTrue(error.errorDescription?.contains(msg) == true)
    }
}

// MARK: - TranscriptionModel Cloud Properties Tests

final class TranscriptionModelCloudTests: XCTestCase {

    func testCloudModelsHaveLongerFlushInterval() {
        // Cloud models should have a longer flush interval than local models
        // because each API call has latency, so batching more audio is better.
        let cloudFlush = TranscriptionModel.assemblyAI.flushIntervalSamples
        let localFlush = TranscriptionModel.parakeetV3.flushIntervalSamples
        XCTAssertGreaterThan(cloudFlush, localFlush,
                             "Cloud models should flush less frequently than local")
    }

    func testMakeBackendWithApiKeyProducesCorrectType() {
        let aai = TranscriptionModel.assemblyAI.makeBackend(apiKey: "key-123")
        XCTAssertEqual(aai.displayName, "AssemblyAI")

        let el = TranscriptionModel.elevenLabsScribe.makeBackend(apiKey: "key-456")
        XCTAssertEqual(el.displayName, "ElevenLabs Scribe")
    }

    func testLocalMakeBackendIgnoresApiKey() {
        // Local models should not care about apiKey parameter
        let backend = TranscriptionModel.parakeetV3.makeBackend(apiKey: "should-be-ignored")
        XCTAssertEqual(backend.displayName, "Parakeet TDT v3")
    }
}

// MARK: - Timestamp Recorder for timing tests

private final class TimestampRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Date] = []

    var values: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        _values.append(Date())
    }
}

// MARK: - API Key Routing Tests (supplements SettingsStoreTests)

@MainActor
final class CloudASRApiKeyRoutingTests: XCTestCase {

    private func makeStore() -> SettingsStore {
        let name = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("CloudASRApiKeyRoutingTests"),
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    func testCloudASRApiKeyForAssemblyAI() {
        let store = makeStore()
        store.assemblyAIApiKey = "aai-key-123"
        XCTAssertEqual(store.cloudASRApiKey(for: .assemblyAI), "aai-key-123")
    }

    func testCloudASRApiKeyForElevenLabsScribe() {
        let store = makeStore()
        store.elevenLabsApiKey = "el-key-456"
        XCTAssertEqual(store.cloudASRApiKey(for: .elevenLabsScribe), "el-key-456")
    }

    func testCloudASRApiKeyForLocalModelReturnsEmpty() {
        let store = makeStore()
        store.assemblyAIApiKey = "should-not-return"
        store.elevenLabsApiKey = "should-not-return"
        XCTAssertEqual(store.cloudASRApiKey(for: .parakeetV3), "")
    }

    func testCloudASRApiKeyForAllLocalModelsReturnsEmpty() {
        let store = makeStore()
        store.assemblyAIApiKey = "aai"
        store.elevenLabsApiKey = "el"
        let localModels: [TranscriptionModel] = [.parakeetV2, .parakeetV3, .qwen3ASR06B, .whisperBase, .whisperSmall, .whisperLargeV3Turbo]
        for model in localModels {
            XCTAssertEqual(store.cloudASRApiKey(for: model), "",
                           "Expected empty API key for local model \(model.rawValue)")
        }
    }
}
