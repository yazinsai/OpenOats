import XCTest
@testable import OpenOatsKit

final class DiagnosticsSupportTests: XCTestCase {
    func testDiagnosticsReportIncludesSettingsAndLogs() {
        let appInfo = DiagnosticsReportBuilder.AppInfo(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: "com.openoats.app",
            version: "1.56.0",
            build: "123",
            macOSVersion: "macOS 15.0"
        )
        let settings = DiagnosticsSettingsSnapshot(
            notesGenerationProvider: "openRouter",
            transcriptionModel: "parakeetV3",
            batchTranscriptionModel: "whisperLargeV3Turbo",
            knowledgeRetrievalProvider: "voyageAI",
            knowledgeBaseConfigured: true,
            meetingDetectionEnabled: true,
            calendarIntegrationEnabled: false,
            saveAudioRecording: true,
            batchRetranscriptionEnabled: true,
            diagnosticLoggingEnabled: true
        )

        let report = DiagnosticsReportBuilder.buildText(
            appInfo: appInfo,
            settings: settings,
            breadcrumbs: "[2026-01-01T12:00:00Z] [meeting] Started session",
            unifiedLog: "2026-01-01 12:00:00.000 OpenOats[1:1] test line"
        )

        XCTAssertTrue(report.contains("OpenOats Diagnostics Export"))
        XCTAssertTrue(report.contains("Bundle ID: com.openoats.app"))
        XCTAssertTrue(report.contains("Notes generation: openRouter"))
        XCTAssertTrue(report.contains("Knowledge base configured: yes"))
        XCTAssertTrue(report.contains("[meeting] Started session"))
        XCTAssertTrue(report.contains("test line"))
    }

    func testSystemAudioDiagnosticsMessageIsStructuredJSON() throws {
        let event = SystemAudioCapture.SystemAudioDiagnosticsEvent(
            event: "system_audio_tap_format_exhausted",
            attempt: 2,
            requestedOutputDeviceID: nil,
            resolvedOutputDeviceID: 108,
            outputDeviceAvailable: nil,
            outputDeviceUIDLength: 32,
            availableOutputDeviceCount: 4,
            outputStreamCount: 1,
            outputNominalSampleRate: 16_000,
            outputTransportType: 1_651_271_286,
            processObjectID: 91,
            processCount: 1,
            tapID: 123,
            aggregateDeviceID: 456,
            ioProcCreated: nil,
            status: 560_947_818,
            cleanupAggregateStatus: nil,
            cleanupTapStatus: nil,
            retryIndex: nil,
            retryCount: 40,
            sampleRate: nil,
            channels: nil,
            bytesPerFrame: nil,
            flags: ["isPrivate": true],
            errorKind: nil
        )

        let message = SystemAudioCapture.systemAudioDiagnosticsMessage(for: event)
        let data = try XCTUnwrap(message.data(using: .utf8))
        let decoded = try JSONDecoder().decode(SystemAudioCapture.SystemAudioDiagnosticsEvent.self, from: data)

        XCTAssertEqual(decoded, event)
    }
}
