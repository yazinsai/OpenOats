import Foundation
import OatsCore
import Testing

/// A Notes backend that answers with `reply(system, user)` and records every request.
final class ScriptedNotes: NotesBackend, @unchecked Sendable {
    let name = "scripted-notes"
    let contextTokens: Int
    let reply: @Sendable (String, String) -> String
    private let lock = NSLock()
    private var _requests: [(system: String, user: String)] = []
    var requests: [(system: String, user: String)] { lock.withLock { _requests } }

    init(contextTokens: Int = 100_000, reply: @escaping @Sendable (String, String) -> String) {
        self.contextTokens = contextTokens
        self.reply = reply
    }

    func complete(system: String, user: String) async throws -> String {
        lock.withLock { _requests.append((system, user)) }
        return reply(system, user)
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(_ account: String) -> String? { lock.withLock { values[account] } }
    func setSecret(_ value: String?, _ account: String) { lock.withLock { values[account] = value } }
}

let isVocabularyRequest: @Sendable (String) -> Bool = { $0.contains("JSON array") }

/// Seam 1 with the real Notes step: Meeting folder → Processing → Meeting file.
@Suite final class NotesStepTests: Sendable {
    let ws = Workspace()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    func run(_ tracks: [Track: [TimedSegment]], _ notes: ScriptedNotes, vocabulary: [String] = []) async throws -> String {
        let folder = try ws.recordedMeeting()
        let options = ProcessingOptions(transcription: FakeTranscription(segments: tracks), notes: notes,
                                        notesStep: NotesWriter.step(vocabulary: vocabulary), notesFolder: ws.notesFolder)
        let status = try await Processing.run(folder, options: options)
        #expect(status.state == .done, "\(status.lastError ?? "")")
        return try ws.onlyMeetingFile()
    }

    @Test func correctsVocabularyAndLeavesTheTranscriptOtherwiseVerbatim() async throws {
        let notes = ScriptedNotes { system, _ in
            isVocabularyRequest(system)
                ? #"Sure: [{"from": "an arai", "to": "almarai"}, {"from": "gonna", "to": "going to"}]"#
                : "Title: Almarai rollout\n\n## Summary\n\nWe discussed the Almarai rollout."
        }
        let tracks: [Track: [TimedSegment]] = [.mic: [seg(0, 3, "So we're gonna ship an arai next week, An Arai's team agreed.")],
                      .system: [seg(4, 6, "Great, the canary build is ready.")]]
        let file = try await run(tracks, notes, vocabulary: ["Almarai", "Talabat"])

        #expect(file.contains("[00:00:00] **You:** So we're gonna ship Almarai next week, Almarai's team agreed.\n"))
        #expect(file.contains("[00:00:04] **Them:** Great, the canary build is ready.\n"))
        let notesRequest = try #require(notes.requests.last)
        #expect(notesRequest.user.contains("ship Almarai next week"))
        #expect(notesRequest.system.contains("Almarai, Talabat"))
        #expect(notes.requests.first.map { $0.system.contains("Almarai, Talabat") } == true)
    }

    @Test func rejectsVocabularyReplacementsThatSwallowNeighbouringWords() async throws {
        let notes = ScriptedNotes { system, _ in
            isVocabularyRequest(system)
                ? #"[{"from": "arai milk", "to": "Almarai"}, {"from": "the labar", "to": "Talabat"}]"#
                : "Title: Groceries\n\n## Summary\n\nOrders."
        }
        let tracks: [Track: [TimedSegment]] = [.mic: [seg(0, 3, "Get an arai milk through the labar app.")]]
        let file = try await run(tracks, notes, vocabulary: ["Almarai", "Talabat"])
        #expect(file.contains("**You:** Get an arai milk through Talabat app.\n"))
    }

    @Test func noVocabularyMeansOneNotesRequest() async throws {
        let notes = ScriptedNotes { _, _ in "Title: Sync\n\n## Summary\n\nShort." }
        _ = try await run(basicTracks, notes)
        #expect(notes.requests.count == 1)
        #expect(notes.requests[0].system.hasPrefix(NotesWriter.defaultPrompt))
        let sections = notes.requests[0].system.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(sections == ["## Summary", "## Decisions", "## Action Items", "## Open Questions"])
    }

    @Test func summarisesLongTranscriptsInPiecesThenCombines() async throws {
        let lines = (0..<200).map { seg(Double($0 * 10), Double($0 * 10 + 5), "Line \($0) about the quarterly roadmap and hiring plan.") }
        let notes = ScriptedNotes(contextTokens: 3_000) { _, user in
            user.hasPrefix("Here is part") ? "Title: Part\n\n## Summary\n\nPart notes." : "Title: Quarterly Planning\n\n## Summary\n\nCombined notes."
        }
        let file = try await run([.mic: lines], notes)

        let parts = notes.requests.filter { $0.user.hasPrefix("Here is part") }
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.user.count < 3_000 * 4 })
        for i in [0, 99, 199] { #expect(parts.contains { $0.user.contains("Line \(i) about") }) }
        #expect(notes.requests.last?.user.contains("notes from consecutive parts") == true)
        #expect(file.contains("# Quarterly Planning\n\n## Summary\n\nCombined notes.\n"))
        #expect(!file.contains("Part notes."))
    }

    @Test func omitsEmptySectionsAndNamesTheFileAfterTheTitle() async throws {
        let notes = ScriptedNotes { _, _ in
            "Title: Q1 Launch: Planning\n\n## Summary\n\nWe moved the launch.\n\n## Action Items\n\n- None\n\n## Decisions\n\n- Launch on April 15\n\n## Open Questions\n\n"
        }
        let file = try await run(basicTracks, notes)

        #expect(ws.meetingFiles.map(\.lastPathComponent) == ["\(ws.datePrefix)-q1-launch-planning.md"])
        #expect(file.contains("# Q1 Launch: Planning\n\n## Summary\n\nWe moved the launch.\n\n## Decisions\n\n- Launch on April 15\n\n## Transcript"))
        #expect(!file.contains("## Action Items"))
        #expect(!file.contains("## Open Questions"))
    }

    @Test func emptyNotesNeedAttention() async throws {
        let folder = try ws.recordedMeeting()
        let options = ProcessingOptions(transcription: FakeTranscription(segments: basicTracks),
                                        notes: ScriptedNotes { _, _ in "Title: X\n\n## Summary\n\n" }, notesFolder: ws.notesFolder)
        let status = try await Processing.run(folder, options: options)
        #expect(status.state == .needsAttention)
        #expect(status.lastError?.hasPrefix("Needs attention: the Notes weren't written. The model returned empty notes") == true)
    }
}

/// Settings → backends → Processing (seam 1), with a fake Keychain and fake backend types.
@Suite final class SettingsTests: @unchecked Sendable {
    let ws = Workspace()
    let defaults = UserDefaults(suiteName: "oats-tests-\(UUID().uuidString)")!
    let secrets = MemorySecrets()
    deinit { try? FileManager.default.removeItem(at: ws.root) }

    /// Fake backend types; `seen` records the setup each was built from.
    func store(notes: ScriptedNotes, seen: SetupLog = SetupLog()) -> SettingsStore {
        SettingsStore(defaults: defaults, secrets: secrets, makers: BackendMakers(
            transcription: [.onDevice: { _ in FakeTranscription(segments: basicTracks) }],
            notes: [.openAICompatible: { seen.add($0); return notes }]
        ))
    }

    @Test func defaultsKeepEverythingOnTheMac() {
        let settings = SettingsStore(defaults: defaults, secrets: secrets).load()
        #expect(settings.transcription.type == .onDevice)
        #expect(settings.notes.type == .none)
        #expect(settings.language == nil && !settings.meetingLanguage.isEmpty)
        #expect(settings.notesPrompt == nil && settings.vocabulary.isEmpty && !settings.deleteAudioAfterProcessing)
        #expect(settings.notesFolder.path.hasSuffix("Documents/OpenOats"))
    }

    @Test func skipsNotesStepWithoutNotesBackend() async throws {
        let notes = ScriptedNotes { _, _ in "Title: Never" }
        let store = store(notes: notes)
        var settings = store.load()
        settings.notesFolder = ws.notesFolder
        store.save(settings)

        let status = try await Processing.run(try ws.recordedMeeting(), options: store.processingOptions())
        #expect(status.state == .done)
        #expect(notes.requests.isEmpty)
        #expect(!(try ws.onlyMeetingFile()).contains("## Summary"))
    }

    @Test func savedSettingsDrivePresetKeyPromptVocabularyAndAudio() async throws {
        let seen = SetupLog()
        let notes = ScriptedNotes { system, _ in isVocabularyRequest(system) ? "[]" : "Title: Haiku\n\n## Summary\n\nShort." }
        let store = store(notes: notes, seen: seen)
        var settings = Settings()
        settings.notesFolder = ws.notesFolder
        settings.notes = try #require(Preset<NotesBackendType>.all.first { $0.name == "OpenRouter" }).config
        settings.notesPrompt = "Write the notes as a haiku."
        settings.vocabulary = ["Almarai"]
        settings.deleteAudioAfterProcessing = true
        store.save(settings)
        store.setAPIKey("sk-or-test", for: settings.notes)
        #expect(store.load() == settings)

        let folder = try ws.recordedMeeting()
        let status = try await Processing.run(folder, options: store.processingOptions())
        #expect(status.state == .done)
        let setup = try #require(seen.setups.first)
        #expect(setup.address == "https://openrouter.ai/api/v1" && setup.model == "google/gemini-3-flash-preview")
        #expect(setup.apiKey == "sk-or-test" && setup.contextTokens >= 100_000)
        #expect(notes.requests.last?.system.hasPrefix("Write the notes as a haiku.") == true)
        #expect(ws.files(in: folder).isDisjoint(with: ["mic.pcm", "system.pcm", "mic.m4a", "system.m4a"]))

        settings.notesPrompt = nil // Reset
        store.save(settings)
        _ = try await Processing.run(try ws.recordedMeeting(), options: store.processingOptions())
        #expect(notes.requests.last?.system.hasPrefix(NotesWriter.defaultPrompt) == true)
    }

    @Test func localPresetWithCustomModelNeedsNoKey() async throws {
        let seen = SetupLog()
        let store = store(notes: ScriptedNotes { _, _ in "## Summary\n\nOk." }, seen: seen)
        var settings = Settings()
        settings.notesFolder = ws.notesFolder
        settings.notes = try #require(Preset<NotesBackendType>.all.first { $0.name == "Ollama" }).config
        settings.notes.model = "llama3.2"
        store.save(settings)

        _ = try await Processing.run(try ws.recordedMeeting(), options: store.processingOptions())
        let setup = try #require(seen.setups.first)
        #expect(setup.address == "http://localhost:11434/v1" && setup.model == "llama3.2")
        #expect(setup.apiKey == nil && setup.contextTokens == 8_192) // Ollama is sent num_ctx 8192

        settings.notes = try #require(Preset<NotesBackendType>.all.first { $0.name == "LM Studio" }).config
        store.save(settings)
        _ = try await Processing.run(try ws.recordedMeeting(), options: store.processingOptions())
        #expect(seen.setups.last?.contextTokens == 4_096) // a local server's context is unknown; assume a small one
    }

    @Test func backendTypeMissingFromThisBuildNeedsAttention() async throws {
        let store = store(notes: ScriptedNotes { _, _ in "" })
        var settings = Settings()
        settings.notesFolder = ws.notesFolder
        settings.notes = NotesConfig(type: .gemini)
        store.save(settings)

        let status = try await Processing.run(try ws.recordedMeeting(), options: store.processingOptions())
        #expect(status.state == .needsAttention)
        #expect(status.lastError?.contains("isn't available") == true)
        #expect(ws.meetingFiles.count == 1)
    }

    @Test func presetsAreValid() {
        func check<K>(_ presets: [Preset<K>]) {
            #expect(Set(presets.map(\.name)).count == presets.count)
            for preset in presets {
                let url = URL(string: preset.address)
                #expect(url?.host() != nil, "\(preset.name)")
                let local = url?.host() == "localhost"
                #expect(url?.scheme == (local ? "http" : "https"), "\(preset.name)")
                #expect(preset.needsKey == !local, "\(preset.name)")
                // AssemblyAI picks its current speech model itself (not pinned, so deprecations need no app update).
                #expect(local || preset.name == "AssemblyAI" || preset.model?.isEmpty == false, "cloud Preset \(preset.name) needs a default model")
                #expect(preset.config.preset == preset.name)
            }
        }
        check(Preset<NotesBackendType>.all)
        check(Preset<TranscriptionBackendType>.all)
        #expect(Preset<NotesBackendType>.all.allSatisfy { $0.type != .none })
        #expect(Preset<TranscriptionBackendType>.all.allSatisfy { $0.type != .onDevice })
        let names = Set(Preset<NotesBackendType>.all.map(\.name))
        #expect(names.isSuperset(of: ["OpenAI", "OpenRouter", "Requesty", "Ollama", "LM Studio", "MLX", "llama.cpp"]))
        #expect(Set(Preset<TranscriptionBackendType>.all.map(\.name)) == ["OpenAI", "Groq", "Self-hosted Whisper", "ElevenLabs", "AssemblyAI", "Gemini"])
    }
}

final class SetupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _setups: [BackendSetup<NotesBackendType>] = []
    var setups: [BackendSetup<NotesBackendType>] { lock.withLock { _setups } }
    func add(_ setup: BackendSetup<NotesBackendType>) { lock.withLock { _setups.append(setup) } }
}
