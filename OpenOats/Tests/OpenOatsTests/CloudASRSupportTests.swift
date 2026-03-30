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
