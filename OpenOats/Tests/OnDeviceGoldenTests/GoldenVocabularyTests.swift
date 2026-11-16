import Foundation
import OatsCore
import OatsOnDevice
import Testing

/// Opt-in (`OATS_GOLDEN_NOTES=1`, plus the clip): the clip through on-device transcription and a real OpenAI-compatible
/// Notes backend (cliproxy, credentials read here from ~/.config/cliproxyapi/credentials.env, never printed) with the
/// Vocabulary [Almarai, Talabat]. On-device alone hears "an arai" or "an array"; the Transcript must
/// say "Almarai". `OATS_GOLDEN_NOTES_MODEL` picks the model (default gemini-3-flash).
@Suite(.enabled(if: hasClip && ProcessInfo.processInfo.environment["OATS_GOLDEN_NOTES"] == "1"))
struct GoldenVocabularyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oats-golden-notes-\(UUID().uuidString)")

    static func credentials() throws -> [String: String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cliproxyapi/credentials.env")
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").reduce(into: [:]) { env, line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            if parts.count == 2, !parts[0].hasPrefix("#") { env[parts[0].replacingOccurrences(of: "export ", with: "")] = parts[1] }
        }
    }

    @Test func vocabularyFixesTheTranscript() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let env = try Self.credentials()
        let model = ProcessInfo.processInfo.environment["OATS_GOLDEN_NOTES_MODEL"] ?? "gemini-3-flash"
        let address = try #require(env["OPENAI_BASE_URL"]), key = try #require(env["OPENAI_API_KEY"])
        let notes = OpenAICompatibleNotes(BackendSetup(type: .openAICompatible, address: address, model: model, apiKey: key,
                                                       contextTokens: 128_000))
        let folder = try MeetingStore(root: root.appendingPathComponent("Meetings")).importAudio([clip], language: "en")
        let status = try await Processing.run(folder, options: ProcessingOptions(
            transcription: OnDeviceTranscription(language: "en"), notes: notes,
            notesStep: NotesWriter.step(vocabulary: ["Almarai", "Talabat"]), notesFolder: root.appendingPathComponent("Notes"),
            keepAudio: false))

        #expect(status.state == .done, "\(status.lastError ?? "")")
        let file = try String(contentsOfFile: try #require(status.meetingFile), encoding: .utf8)
        let transcript = file.components(separatedBy: "## Transcript")[1]
        let hits = transcript.components(separatedBy: "Almarai").count - 1
        print("golden vocabulary (\(model)): Transcript has \"Almarai\" \(hits)×, \"an arai\" \(transcript.lowercased().components(separatedBy: "an arai").count - 1)×")
        #expect(hits > 0)
        #expect(!transcript.lowercased().contains("an arai"))
    }
}
