import AppKit
import Foundation
import UniformTypeIdentifiers

struct DiagnosticsSettingsSnapshot: Sendable, Equatable {
    let notesGenerationProvider: String
    let transcriptionModel: String
    let batchTranscriptionModel: String
    let knowledgeRetrievalProvider: String
    let knowledgeBaseConfigured: Bool
    let meetingDetectionEnabled: Bool
    let calendarIntegrationEnabled: Bool
    let saveAudioRecording: Bool
    let batchRetranscriptionEnabled: Bool
    let diagnosticLoggingEnabled: Bool

    init(
        notesGenerationProvider: String,
        transcriptionModel: String,
        batchTranscriptionModel: String,
        knowledgeRetrievalProvider: String,
        knowledgeBaseConfigured: Bool,
        meetingDetectionEnabled: Bool,
        calendarIntegrationEnabled: Bool,
        saveAudioRecording: Bool,
        batchRetranscriptionEnabled: Bool,
        diagnosticLoggingEnabled: Bool
    ) {
        self.notesGenerationProvider = notesGenerationProvider
        self.transcriptionModel = transcriptionModel
        self.batchTranscriptionModel = batchTranscriptionModel
        self.knowledgeRetrievalProvider = knowledgeRetrievalProvider
        self.knowledgeBaseConfigured = knowledgeBaseConfigured
        self.meetingDetectionEnabled = meetingDetectionEnabled
        self.calendarIntegrationEnabled = calendarIntegrationEnabled
        self.saveAudioRecording = saveAudioRecording
        self.batchRetranscriptionEnabled = batchRetranscriptionEnabled
        self.diagnosticLoggingEnabled = diagnosticLoggingEnabled
    }

    @MainActor
    init(settings: SettingsStore) {
        notesGenerationProvider = settings.llmProvider.rawValue
        transcriptionModel = settings.transcriptionModel.rawValue
        batchTranscriptionModel = settings.batchTranscriptionModel.rawValue
        knowledgeRetrievalProvider = settings.embeddingProvider.rawValue
        knowledgeBaseConfigured = settings.kbFolderURL != nil
        meetingDetectionEnabled = settings.meetingAutoDetectEnabled
        calendarIntegrationEnabled = settings.calendarIntegrationEnabled
        saveAudioRecording = settings.saveAudioRecording
        batchRetranscriptionEnabled = settings.enableBatchRetranscription
        diagnosticLoggingEnabled = settings.diagnosticLoggingEnabled
    }
}

struct DiagnosticsReportBuilder {
    struct AppInfo: Sendable, Equatable {
        let generatedAt: Date
        let bundleIdentifier: String
        let version: String
        let build: String
        let macOSVersion: String
    }

    static func buildText(
        appInfo: AppInfo,
        settings: DiagnosticsSettingsSnapshot,
        breadcrumbs: String,
        unifiedLog: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("OpenOats Diagnostics Export")
        lines.append("Generated at: \(formatter.string(from: appInfo.generatedAt))")
        lines.append("Bundle ID: \(appInfo.bundleIdentifier)")
        lines.append("Version: \(appInfo.version) (\(appInfo.build))")
        lines.append("macOS: \(appInfo.macOSVersion)")
        lines.append("")
        lines.append("Settings")
        lines.append("--------")
        lines.append("Notes generation: \(settings.notesGenerationProvider)")
        lines.append("Transcription model: \(settings.transcriptionModel)")
        lines.append("Batch model: \(settings.batchTranscriptionModel)")
        lines.append("Knowledge retrieval: \(settings.knowledgeRetrievalProvider)")
        lines.append("Knowledge base configured: \(settings.knowledgeBaseConfigured ? "yes" : "no")")
        lines.append("Meeting detection: \(settings.meetingDetectionEnabled ? "on" : "off")")
        lines.append("Calendar integration: \(settings.calendarIntegrationEnabled ? "on" : "off")")
        lines.append("Save audio recording: \(settings.saveAudioRecording ? "on" : "off")")
        lines.append("Batch re-transcription: \(settings.batchRetranscriptionEnabled ? "on" : "off")")
        lines.append("Diagnostic logging: \(settings.diagnosticLoggingEnabled ? "on" : "off")")
        lines.append("")
        lines.append("Breadcrumbs")
        lines.append("-----------")
        lines.append(breadcrumbs.isEmpty ? "(none)" : breadcrumbs)
        lines.append("")
        lines.append("Unified Log")
        lines.append("-----------")
        lines.append(unifiedLog.isEmpty ? "(no recent log entries)" : unifiedLog)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

actor DiagnosticsBreadcrumbStore {
    static let shared = DiagnosticsBreadcrumbStore()

    private let key = "diagnosticLoggingEnabled"
    private let maxLines = 1000

    func record(category: String, message: String) {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        let url = breadcrumbsURL()
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            lines.append(line.trimmingCharacters(in: .newlines))
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }
            let payload = lines.filter { !$0.isEmpty }.joined(separator: "\n")
            try payload.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.diagnostics.error("Failed to append diagnostic breadcrumb: \(error, privacy: .public)")
        }
    }

    func loadContents() -> String {
        let url = breadcrumbsURL()
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func breadcrumbsURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("OpenOats", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("breadcrumbs.log")
    }
}

enum DiagnosticsSupport {
    enum Error: LocalizedError, Equatable {
        case cancelled
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Diagnostics export was cancelled."
            case .writeFailed(let reason):
                return reason
            }
        }
    }

    static func record(category: String, message: String) {
        Task {
            await DiagnosticsBreadcrumbStore.shared.record(category: category, message: message)
        }
    }

    @MainActor
    static func exportInteractively(settings: SettingsStore) async throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename()
        panel.title = "Export Diagnostics"
        panel.message = "Exports recent app logs and a small diagnostics summary for debugging."

        guard panel.runModal() == .OK, let destination = panel.url else {
            throw Error.cancelled
        }

        let report = await generateReport(settings: settings)
        do {
            try report.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            throw Error.writeFailed("Failed to write diagnostics export: \(error.localizedDescription)")
        }
    }

    private static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "openoats-diagnostics-\(formatter.string(from: Date())).txt"
    }

    @MainActor
    private static func generateReport(settings: SettingsStore) async -> String {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "com.openoats.app"
        let appInfo = DiagnosticsReportBuilder.AppInfo(
            generatedAt: Date(),
            bundleIdentifier: bundleID,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let settingsSnapshot = DiagnosticsSettingsSnapshot(settings: settings)
        let breadcrumbs = await DiagnosticsBreadcrumbStore.shared.loadContents()
        let unifiedLog = await unifiedLogReport(bundleIdentifier: bundleID)
        return DiagnosticsReportBuilder.buildText(
            appInfo: appInfo,
            settings: settingsSnapshot,
            breadcrumbs: breadcrumbs,
            unifiedLog: unifiedLog
        )
    }

    private static func unifiedLogReport(bundleIdentifier: String) async -> String {
        await Task.detached(priority: .utility) {
            let subsystems = Set([bundleIdentifier, "com.openoats.app"]).sorted()
            let predicate = subsystems
                .map { "subsystem == \"\($0)\"" }
                .joined(separator: " OR ")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--style", "compact",
                "--last", "2h",
                "--predicate", predicate,
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    return output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let detail = errors.isEmpty ? output : errors
                return "Failed to collect recent unified logs.\n\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                return "Failed to collect recent unified logs.\n\(error.localizedDescription)"
            }
        }.value
    }
}
