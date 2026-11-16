import Foundation
import Testing
@testable import OatsCore

/// Core-level migration: fixture 1.x defaults and Keychain values → v2 Settings and keys.
@Suite final class MigrationTests: @unchecked Sendable {
    let defaults = UserDefaults(suiteName: "oats-migration-\(UUID().uuidString)")!
    let secrets = MemorySecrets()
    var store: SettingsStore { SettingsStore(defaults: defaults, secrets: secrets) }

    func migrate(_ old: [String: Any], keys: [String: String] = [:]) -> Settings {
        for (k, v) in old { defaults.set(v, forKey: k) }
        for (a, v) in keys { secrets.setSecret(v, a) }
        #expect(Migration.runIfNeeded(store))
        return store.load()
    }

    @Test func carriesOverAFull1xInstall() {
        let s = migrate([
            "notesFolderPath": "/Users/x/Documents/OpenGranola",
            "transcriptionLocale": "de-DE",
            "transcriptionCustomVocabulary": "Kubernetes\nOpenOats: open oats, open notes\n\n",
            "saveAudioRecording": false,
            "llmProvider": "openRouter", "selectedModel": "anthropic/claude-haiku-4.5",
            "transcriptionModel": "parakeetV3", "batchTranscriptionModel": "whisperSmall",
        ], keys: ["openRouterApiKey": "or-fixture", "voyageApiKey": "voyage-fixture"])
        #expect(s.notesFolder.path == "/Users/x/Documents/OpenGranola")
        #expect(s.language == "de")
        #expect(s.vocabulary == ["Kubernetes", "OpenOats"])
        #expect(s.deleteAudioAfterProcessing)
        #expect(s.notes == NotesConfig(type: .openAICompatible, address: "https://openrouter.ai/api/v1",
                                       model: "anthropic/claude-haiku-4.5", preset: "OpenRouter"))
        #expect(store.apiKey(for: s.notes) == "or-fixture")
        #expect(s.transcription.type == .onDevice)
        #expect(secrets.secret("openRouterApiKey") == "or-fixture") // 1.x item left in place
    }

    @Test func emptyInstallGetsDefaults() {
        let s = migrate([:])
        #expect(s == Settings())
        #expect(s.notes.type == .none && s.transcription.type == .onDevice)
    }

    @Test func providerWithoutItsKeyFallsBackToNoNotes() {
        #expect(migrate(["llmProvider": "anthropic", "anthropicModel": "claude-opus-4"]).notes.type == .none)
    }

    @Test func unknownProviderAndModelFallBackToDefaults() {
        let s = migrate(["llmProvider": "someFutureProvider", "transcriptionModel": "barkPlus"])
        #expect(s.notes.type == .none)
        #expect(s.transcription.type == .onDevice)
    }

    @Test func localProviderKeepsCustomAddressWithoutAKey() {
        let s = migrate(["llmProvider": "ollama", "ollamaBaseURL": "http://192.168.1.5:11434"])
        #expect(s.notes == NotesConfig(type: .openAICompatible, address: "http://192.168.1.5:11434", model: "qwen3:8b", preset: "Ollama"))
    }

    @Test func customOpenAICompatibleProvider() {
        let s = migrate(["llmProvider": "openAICompatible", "openAILLMBaseURL": "https://llm.example.com/v1", "openAILLMModel": "m"],
                        keys: ["openAILLMApiKey": "custom-fixture"])
        #expect(s.notes == NotesConfig(type: .openAICompatible, address: "https://llm.example.com/v1", model: "m"))
        #expect(store.apiKey(for: s.notes) == "custom-fixture")
    }

    @Test func batchModelWinsWhenBatchWasOn() {
        let s = migrate(["transcriptionModel": "parakeetV2", "enableBatchRetranscription": true, "batchTranscriptionModel": "elevenLabsScribe"],
                        keys: ["elevenLabsApiKey": "el-fixture"])
        #expect(s.transcription == Preset<TranscriptionBackendType>.all.first { $0.name == "ElevenLabs" }!.config)
        #expect(store.apiKey(for: s.transcription) == "el-fixture")
    }

    @Test func cloudTranscriptionWithoutKeyFallsBackToOnDevice() {
        #expect(migrate(["transcriptionModel": "assemblyAI"]).transcription.type == .onDevice)
    }

    @Test func droppedCohereGoesOnDevice() {
        #expect(migrate(["transcriptionModel": "cohereTranscribeArabic"], keys: ["cohereApiKey": "c"]).transcription.type == .onDevice)
    }

    @Test func unusedKeysStillMoveSoSwitchingPresetsFindsThem() {
        let s = migrate(["llmProvider": "ollama"], keys: ["anthropicApiKey": "an-fixture", "assemblyAIApiKey": "aai-fixture"])
        #expect(s.notes.preset == "Ollama")
        #expect(store.apiKey(for: NotesConfig(type: .anthropic, preset: "Anthropic")) == "an-fixture")
        #expect(store.apiKey(for: TranscriptionConfig(type: .assemblyAI, preset: "AssemblyAI")) == "aai-fixture")
    }

    @Test func runsOnlyOnce() {
        _ = migrate(["transcriptionCustomVocabulary": "First"])
        var changed = store.load()
        changed.vocabulary = ["Edited in v2"]
        store.save(changed)
        defaults.set("Second", forKey: "transcriptionCustomVocabulary")
        #expect(!Migration.runIfNeeded(store))
        #expect(store.load().vocabulary == ["Edited in v2"])
    }

    @Test func leaves1xSessionFilesAlone() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let session = support.appendingPathComponent("sessions/session_2026-01-01_10-00-00/transcript.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"text\":\"hi\"}\n".utf8).write(to: session)
        let before = try FileManager.default.attributesOfItem(atPath: session.path)[.modificationDate] as? Date
        _ = migrate(["notesFolderPath": support.path])
        #expect(try Data(contentsOf: session) == Data("{\"text\":\"hi\"}\n".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: session.path)[.modificationDate] as? Date == before)
    }
}
