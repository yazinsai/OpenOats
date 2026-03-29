import XCTest
@testable import OpenOatsKit

@MainActor
final class TranscriptionEngineTests: XCTestCase {
    // MARK: - Helpers

    private func makeSettings() -> AppSettings {
        let suiteName = "com.openoats.tests.transcription-engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    // MARK: - Active Session Model

    func testActiveTranscriptionSessionCapturesModelForFlushAndCacheClearing() {
        let session = ActiveTranscriptionSession(transcriptionModel: .whisperLargeV3Turbo)
        XCTAssertEqual(
            session.flushIntervalSamples,
            TranscriptionModel.whisperLargeV3Turbo.flushIntervalSamples
        )

        let backend = CacheClearingBackend()
        var capturedModel: TranscriptionModel?
        session.clearModelCache(using: { model in
            capturedModel = model
            return backend
        })

        XCTAssertEqual(capturedModel, .whisperLargeV3Turbo)
        XCTAssertEqual(backend.clearModelCacheCallCount, 1)
    }

    func testCurrentTranscriptionModelPrefersActiveSessionOverMutableSettings() {
        let settings = makeSettings()
        settings.transcriptionModel = .parakeetV2

        let engine = TranscriptionEngine(
            transcriptStore: TranscriptStore(),
            settings: settings,
            mode: .scripted([])
        )
        engine.activeTranscriptionSession = ActiveTranscriptionSession(
            transcriptionModel: .whisperBase
        )

        settings.transcriptionModel = .qwen3ASR06B

        XCTAssertEqual(engine.currentTranscriptionModel(), .whisperBase)
    }

    // MARK: - Diarization Feed Gate

    func testDiarizationFeedRelayStopsAfterFirstFailure() async {
        var relay = DiarizationFeedRelay()
        let recorder = FeedRecorder(failOnCall: 2)
        let errorRecorder = ErrorRecorder()

        await relay.feedAudio(
            [1.0, 2.0],
            into: { samples in try await recorder.feed(samples) },
            onFailure: { error in await errorRecorder.record(error) }
        )
        await relay.feedAudio(
            [3.0, 4.0],
            into: { samples in try await recorder.feed(samples) },
            onFailure: { error in await errorRecorder.record(error) }
        )
        await relay.feedAudio(
            [5.0, 6.0],
            into: { samples in try await recorder.feed(samples) },
            onFailure: { error in await errorRecorder.record(error) }
        )

        let recordedBatches = await recorder.snapshotBatches()
        let failureCount = await errorRecorder.snapshotCount()

        XCTAssertEqual(recordedBatches, [[1.0, 2.0], [3.0, 4.0]])
        XCTAssertTrue(relay.hasFailed)
        XCTAssertEqual(failureCount, 1)
    }
}

// MARK: - Test Helpers

private final class CacheClearingBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Mock cache clearing backend"
    private(set) var clearModelCacheCallCount = 0

    func checkStatus() -> BackendStatus {
        .ready
    }

    func prepare(
        onStatus: @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String?
    ) async throws -> String {
        ""
    }

    func clearModelCache() {
        clearModelCacheCallCount += 1
    }
}

private actor FeedRecorder {
    private(set) var batches: [[Float]] = []
    private let failOnCall: Int?
    private var callCount = 0

    init(failOnCall: Int?) {
        self.failOnCall = failOnCall
    }

    func feed(_ batch: [Float]) throws {
        callCount += 1
        batches.append(batch)

        if callCount == failOnCall {
            struct RelayFailure: Error {}
            throw RelayFailure()
        }
    }

    func snapshotBatches() -> [[Float]] {
        batches
    }
}

private actor ErrorRecorder {
    private(set) var count = 0

    func record(_ error: Error) {
        count += 1
    }

    func snapshotCount() -> Int {
        count
    }
}
