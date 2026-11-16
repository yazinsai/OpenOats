import Foundation
import Testing

/// Seam 2 end to end: `oats record` as a child process, killed with SIGKILL, then recovered by `oats recover`.
@Suite(.serialized) final class RecordCommandTests: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oats-record-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: root) }

    static var oats: URL? {
        // Built next to the tests by `swift test`.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/debug/oats")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.standardizedFileURL : nil
    }

    func launch(_ args: [String], fakeDelay: Double = 0) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = Self.oats
        process.arguments = args + ["--notes-folder", root.appendingPathComponent("Notes").path]
        process.environment = ["OATS_MEETINGS_DIR": root.appendingPathComponent("Meetings").path, "OATS_FAKE_TRANSCRIPTION": "\(fakeDelay)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, out)
    }

    /// Runs `oats recover` to completion and returns the Meeting file it wrote.
    func recover() throws -> String {
        let (process, out) = try launch(["recover"])
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let path = try #require(output.split(separator: "\n").first.map(String.init))
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Reads the first line (`recording <id>`), returning the Meeting folder and when recording began.
    func recordingStarted(_ out: Pipe) throws -> (URL, Date) {
        var line = Data()
        while let byte = try out.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) { line += byte }
        let id = String(decoding: line, as: UTF8.self).replacingOccurrences(of: "recording ", with: "")
        return (root.appendingPathComponent("Meetings").appendingPathComponent(id), Date())
    }

    func state(_ folder: URL) -> String? {
        let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["state"] as? String
    }

    @Test(.enabled(if: oats != nil)) func killedMidRecordingRecoversWithAtMost5SecondsLost() throws {
        let (process, out) = try launch(["record", "--fake-source"])
        let (folder, started) = try recordingStarted(out)
        Thread.sleep(forTimeInterval: 7)
        kill(process.processIdentifier, SIGKILL)
        let recorded = Date().timeIntervalSince(started)
        process.waitUntilExit()

        #expect(state(folder) == "recording")
        let bytes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("mic.pcm").path)[.size] as! Int
        let lost = recorded - Double(bytes / 2) / 16_000
        print("audio lost on kill -9 mid-recording: \(String(format: "%.2f", lost)) s")
        #expect(lost <= 5)

        let file = try recover()
        #expect(file.contains("\ninterrupted: true\n"))
        #expect(file.contains("**You:** Mic track lasted \(String(format: "%.2f", Double(bytes / 2) / 16_000)) s"))
        #expect(file.contains("**Them:** System audio, "))
        #expect(state(folder) == "done")
    }

    @Test(.enabled(if: oats != nil)) func killedMidProcessingResumesOnRecover() throws {
        let (process, out) = try launch(["record", "--fake-source", "--seconds", "3"], fakeDelay: 2)
        let (folder, _) = try recordingStarted(out)
        while state(folder) != "processing" { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.5)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(state(folder) == "processing")

        let file = try recover()
        #expect(!file.contains("interrupted"))
        #expect(file.contains("**You:** Mic track lasted 3."))
        #expect(file.contains("**Them:** System audio, 3."))
        #expect(state(folder) == "done")
    }
}
