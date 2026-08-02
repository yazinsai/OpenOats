import AVFoundation
import Speech
import XCTest
@testable import OpenOatsKit

final class SpeechAnalyzerProviderTests: XCTestCase {

    // MARK: - TranscriptionModel wiring (no Speech runtime)

    func testSpeechAnalyzerUsesStreamingSessionOnly() {
        XCTAssertTrue(TranscriptionModel.speechAnalyzer.usesStreamingSession)
        for model in TranscriptionModel.allCases where model != .speechAnalyzer {
            XCTAssertFalse(model.usesStreamingSession)
        }
    }

    func testIsSelectableOnCurrentOSMatchesAvailability() {
        let selectable = TranscriptionModel.speechAnalyzer.isSelectableOnCurrentOS
        if #available(macOS 26, *) {
            XCTAssertTrue(selectable)
        } else {
            XCTAssertFalse(selectable)
        }
    }

    func testSettingsPickerSourceExcludesUnselectable() {
        let local = TranscriptionModel.allCases.filter { !$0.isCloud && $0.isSelectableOnCurrentOS }
        if #available(macOS 26, *) {
            XCTAssertTrue(local.contains(.speechAnalyzer))
        } else {
            XCTAssertFalse(local.contains(.speechAnalyzer))
        }
    }

    func testNotInBatchSuitableModels() {
        XCTAssertFalse(TranscriptionModel.batchSuitableModels.contains(.speechAnalyzer))
    }

    func testShouldLoadVADFalseForSpeechAnalyzer() {
        XCTAssertFalse(TranscriptionEngine.shouldLoadVAD(for: .speechAnalyzer))
        XCTAssertTrue(TranscriptionEngine.shouldLoadVAD(for: .parakeetV3))
    }

    // MARK: - checkStatus (mock asset checker, macOS 26+)

    @available(macOS 26, *)
    func testCheckStatusUnsupportedLocaleReturnsError() async {
        let mock = MockSpeechAssetChecker(supportedLocaleResult: nil)
        let provider = SpeechAnalyzerProvider(assets: mock)
        let locale = Locale(identifier: "xx-XX")

        let status = await provider.checkStatus(locale: locale)

        guard case .error(let reason) = status else {
            XCTFail("Expected .error, got \(status)")
            return
        }
        XCTAssertTrue(reason.contains("does not support locale"))
        XCTAssertTrue(reason.contains("xx-XX"))
    }

    @available(macOS 26, *)
    func testCheckStatusSupportedButNotInstalledReturnsNeedsDownload() async {
        let resolved = Locale(identifier: "en-US")
        let mock = MockSpeechAssetChecker(
            supportedLocaleResult: resolved,
            installedLocalesResult: []
        )
        let provider = SpeechAnalyzerProvider(assets: mock)

        let status = await provider.checkStatus(locale: resolved)

        XCTAssertEqual(
            status,
            .needsDownload(prompt: TranscriptionModel.speechAnalyzer.downloadPrompt)
        )
    }

    @available(macOS 26, *)
    func testCheckStatusInstalledLocaleReturnsReady() async {
        let resolved = Locale(identifier: "en-US")
        let mock = MockSpeechAssetChecker(
            supportedLocaleResult: resolved,
            installedLocalesResult: [resolved]
        )
        let provider = SpeechAnalyzerProvider(assets: mock)

        let status = await provider.checkStatus(locale: resolved)

        XCTAssertEqual(status, .ready)
    }

    @available(macOS 26, *)
    func testCheckStatusEquivalentInstalledLocaleReturnsReady() async {
        let resolved = Locale(identifier: "en-US")
        let installedVariant = Locale(identifier: "en_US")
        let mock = MockSpeechAssetChecker(
            supportedLocaleResult: resolved,
            installedLocalesResult: [installedVariant],
            equivalentLocaleMap: [installedVariant: resolved]
        )
        let provider = SpeechAnalyzerProvider(assets: mock)

        let status = await provider.checkStatus(locale: resolved)

        XCTAssertEqual(status, .ready)
    }

    @available(macOS 26, *)
    func testProviderDisplayName() {
        let provider = SpeechAnalyzerProvider(assets: MockSpeechAssetChecker())
        XCTAssertEqual(provider.displayName, "Apple SpeechAnalyzer")
    }

    // MARK: - Integration smoke (macOS 26+, real Speech assets)

    func testSpeechAnalyzerSessionSmoke() async throws {
        try XCTSkipUnless({
            if #available(macOS 26, *) { return true }
            return false
        }(), "Requires macOS 26+")

        if #available(macOS 26, *) {
            try await runSpeechAnalyzerSessionSmoke()
        }
    }
}

// MARK: - Integration helpers

@available(macOS 26, *)
private extension SpeechAnalyzerProviderTests {
    func runSpeechAnalyzerSessionSmoke() async throws {
        let provider = SpeechAnalyzerProvider()
        let locale = Locale(identifier: "en-US")
        let status = await provider.checkStatus(locale: locale)

        switch status {
        case .needsDownload:
            throw XCTSkip("Apple speech assets not installed for \(locale.identifier)")
        case .error(let reason):
            throw XCTSkip("Locale not supported: \(reason)")
        case .ready:
            break
        case .downloading:
            throw XCTSkip("Speech assets are currently downloading")
        }

        let session = try await provider.makeSession(locale: locale)
        let stream = makeBriefSilenceStream(sampleRate: 16_000, bufferCount: 3, framesPerBuffer: 1_600)

        await session.run(
            stream: stream,
            onPartial: { _ in },
            onFinal: { _ in }
        )
        await session.finish()
    }

    func makeBriefSilenceStream(
        sampleRate: Double,
        bufferCount: Int,
        framesPerBuffer: AVAudioFrameCount
    ) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            )!
            for _ in 0..<bufferCount {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer) else {
                    continue
                }
                buffer.frameLength = framesPerBuffer
                if let channelData = buffer.floatChannelData {
                    for i in 0..<Int(framesPerBuffer) {
                        channelData[0][i] = 0
                    }
                }
                // AVAudioPCMBuffer is not Sendable; mirror production capture taps.
                nonisolated(unsafe) let unsafeBuffer = buffer
                continuation.yield(unsafeBuffer)
            }
            continuation.finish()
        }
    }
}

// MARK: - Mock asset checker

@available(macOS 26, *)
private struct MockSpeechAssetChecker: SpeechAssetChecking {
    var supportedLocaleResult: Locale?
    var installedLocalesResult: [Locale] = []
    var equivalentLocaleMap: [Locale: Locale] = [:]

    init(
        supportedLocaleResult: Locale? = Locale(identifier: "en-US"),
        installedLocalesResult: [Locale] = [],
        equivalentLocaleMap: [Locale: Locale] = [:]
    ) {
        self.supportedLocaleResult = supportedLocaleResult
        self.installedLocalesResult = installedLocalesResult
        self.equivalentLocaleMap = equivalentLocaleMap
    }

    func supportedLocales() async -> [Locale] {
        if let supportedLocaleResult {
            return [supportedLocaleResult]
        }
        return []
    }

    func installedLocales() async -> [Locale] {
        installedLocalesResult
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        if let mapped = equivalentLocaleMap[locale] {
            return mapped
        }
        if let supportedLocaleResult, locale == supportedLocaleResult {
            return supportedLocaleResult
        }
        return supportedLocaleResult
    }

    func status(for modules: [any SpeechModule]) async -> AssetInventory.Status {
        .installed
    }

    func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest? {
        nil
    }

    func reservedLocales() async -> [Locale] {
        []
    }

    func release(reservedLocale: Locale) async -> Bool {
        true
    }
}
