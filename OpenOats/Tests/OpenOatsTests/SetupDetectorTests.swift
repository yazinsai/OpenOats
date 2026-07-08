import CoreAudio
import XCTest
@testable import OpenOatsKit

final class SetupDetectorTests: XCTestCase {
    private struct MockDependencies: SetupDetector.Dependencies, @unchecked Sendable {
        var physicalMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024
        var preferredLocale = "en-US"
        var audioDevicesList: [(id: AudioDeviceID, name: String)] = []
        var micStatus: MicPermissionStatus = .notDetermined
        var modelStatusMap: [TranscriptionModel: BackendStatus] = [:]
        var openRouterKey = ""
        var voyageKey = ""
        var assemblyAIKey = ""
        var elevenLabsKey = ""
        var cohereKey = ""
        var ollamaFetchResult: Result<[String], OllamaModelFetcher.FetchError> = .failure(.networkError("not probed"))

        func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
            audioDevicesList
        }

        func micAuthorizationStatus() -> MicPermissionStatus {
            micStatus
        }

        func modelStatuses() -> [TranscriptionModel: BackendStatus] {
            modelStatusMap
        }

        func existingOpenRouterKey() async -> String {
            openRouterKey
        }

        func existingVoyageKey() async -> String {
            voyageKey
        }

        func existingAssemblyAIKey() async -> String {
            assemblyAIKey
        }

        func existingElevenLabsKey() async -> String {
            elevenLabsKey
        }

        func existingCohereKey() async -> String {
            cohereKey
        }

        func fetchOllamaModels() async -> Result<[String], OllamaModelFetcher.FetchError> {
            ollamaFetchResult
        }
    }

    func testDetectReturnsRAMFromDependencies() async {
        var deps = MockDependencies()
        deps.physicalMemoryBytes = 8 * 1024 * 1024 * 1024

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertEqual(snapshot.physicalMemoryBytes, 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(snapshot.ramTier, .low)
    }

    func testDetectReturnsLocaleFromDependencies() async {
        var deps = MockDependencies()
        deps.preferredLocale = "de-DE"

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertEqual(snapshot.systemLocale, "de-DE")
        XCTAssertFalse(snapshot.isEnglishLocale)
    }

    func testDetectReturnsExistingKeys() async {
        var deps = MockDependencies()
        deps.openRouterKey = "sk-or-test"
        deps.voyageKey = "pa-test"
        deps.assemblyAIKey = "aai-test"
        deps.elevenLabsKey = "xi-test"
        deps.cohereKey = "co-test"

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertTrue(snapshot.hasOpenRouterKey)
        XCTAssertTrue(snapshot.hasVoyageKey)
        XCTAssertTrue(snapshot.hasAssemblyAIKey)
        XCTAssertTrue(snapshot.hasElevenLabsKey)
        XCTAssertTrue(snapshot.hasCohereKey)
        XCTAssertEqual(snapshot.existingOpenRouterKey, "sk-or-test")
        XCTAssertEqual(snapshot.existingVoyageKey, "pa-test")
        XCTAssertEqual(snapshot.existingAssemblyAIKey, "aai-test")
        XCTAssertEqual(snapshot.existingElevenLabsKey, "xi-test")
        XCTAssertEqual(snapshot.existingCohereKey, "co-test")
    }

    func testDetectReturnsOllamaSuccess() async {
        var deps = MockDependencies()
        deps.ollamaFetchResult = .success(["qwen3:8b", "nomic-embed-text"])

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertTrue(snapshot.ollamaReachable)
        XCTAssertEqual(snapshot.ollamaModels, ["qwen3:8b", "nomic-embed-text"])
    }

    func testDetectReturnsOllamaFailure() async {
        var deps = MockDependencies()
        deps.ollamaFetchResult = .failure(.networkError("timeout"))

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertFalse(snapshot.ollamaReachable)
        XCTAssertTrue(snapshot.ollamaModels.isEmpty)
    }

    func testOllamaStatusReadyWithModels() async {
        var deps = MockDependencies()
        deps.ollamaFetchResult = .success(["qwen3:8b", "nomic-embed-text"])

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        XCTAssertEqual(
            snapshot.ollamaStatus(requiredModels: ["qwen3:8b", "nomic-embed-text"]),
            .readyWithModels
        )
    }

    func testOllamaStatusMissingModels() async {
        var deps = MockDependencies()
        deps.ollamaFetchResult = .success(["llama3:8b"])

        let detector = SetupDetector(dependencies: deps)
        let snapshot = await detector.detect()

        let status = snapshot.ollamaStatus(requiredModels: ["qwen3:8b"])
        if case .missingModels(let missing) = status {
            XCTAssertEqual(missing, ["qwen3:8b"])
        } else {
            XCTFail("Expected missingModels, got \(status)")
        }
    }
}
