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
}
