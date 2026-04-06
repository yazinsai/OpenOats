import XCTest
@testable import OpenOatsKit

@MainActor
final class SidecastPresetTests: XCTestCase {

    private func makeStore() -> SettingsStore {
        let name = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SidecastPresetTests"),
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    // MARK: - New Settings Defaults

    func testDefaultSidecastTemperature() {
        let store = makeStore()
        XCTAssertEqual(store.sidecastTemperature, 1.0)
    }

    func testDefaultSidecastMaxTokens() {
        let store = makeStore()
        XCTAssertEqual(store.sidecastMaxTokens, 700)
    }

    func testDefaultSidecastSystemPrompt() {
        let store = makeStore()
        XCTAssertTrue(store.sidecastSystemPrompt.isEmpty)
    }

    func testDefaultSidecastMinValueThreshold() {
        let store = makeStore()
        XCTAssertEqual(store.sidecastMinValueThreshold, 0.5)
    }

    func testSidecastTemperatureRoundTrip() {
        let store = makeStore()
        store.sidecastTemperature = 0.7
        XCTAssertEqual(store.sidecastTemperature, 0.7)
    }

    func testSidecastMaxTokensRoundTrip() {
        let store = makeStore()
        store.sidecastMaxTokens = 1200
        XCTAssertEqual(store.sidecastMaxTokens, 1200)
    }

    func testSidecastSystemPromptRoundTrip() {
        let store = makeStore()
        store.sidecastSystemPrompt = "You are a custom system prompt."
        XCTAssertEqual(store.sidecastSystemPrompt, "You are a custom system prompt.")
    }

    func testSidecastMinValueThresholdRoundTrip() {
        let store = makeStore()
        store.sidecastMinValueThreshold = 0.3
        XCTAssertEqual(store.sidecastMinValueThreshold, 0.3)
    }

    // MARK: - Preset Decode

    func testDecodeMinimalPreset() throws {
        let json = """
        {"version": 1}
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.version, 1)
        XCTAssertNil(preset.personas)
        XCTAssertNil(preset.intensity)
    }

    func testDecodeFullPreset() throws {
        let json = """
        {
          "version": 1,
          "llmProvider": "openrouter",
          "apiKey": "sk-test-key",
          "baseURL": "",
          "model": "openai/gpt-5.4",
          "temperature": 0.8,
          "maxTokens": 900,
          "intensity": "lively",
          "systemPromptTemplate": "Custom prompt with {{maxMessagesPerTurn}}",
          "minValueThreshold": 0.6,
          "personas": [
            {
              "name": "The Checker",
              "subtitle": "Facts",
              "prompt": "Verify claims.",
              "avatarTint": "green",
              "avatarEmoji": "\\u2714\\uFE0F",
              "verbosity": "short",
              "cadence": "normal",
              "evidencePolicy": "required",
              "isEnabled": true,
              "webSearchEnabled": true
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.llmProvider, "openrouter")
        XCTAssertEqual(preset.apiKey, "sk-test-key")
        XCTAssertEqual(preset.model, "openai/gpt-5.4")
        XCTAssertEqual(preset.temperature, 0.8)
        XCTAssertEqual(preset.maxTokens, 900)
        XCTAssertEqual(preset.intensity, "lively")
        XCTAssertEqual(preset.systemPromptTemplate, "Custom prompt with {{maxMessagesPerTurn}}")
        XCTAssertEqual(preset.minValueThreshold, 0.6)
        XCTAssertEqual(preset.personas?.count, 1)
        XCTAssertEqual(preset.personas?.first?.name, "The Checker")
    }

    // MARK: - Preset Apply

    func testApplyOpenRouterPreset() throws {
        let store = makeStore()
        let json = """
        {
          "version": 1,
          "llmProvider": "openrouter",
          "apiKey": "sk-or-v1-test",
          "model": "anthropic/claude-4-sonnet",
          "temperature": 0.5,
          "maxTokens": 500,
          "intensity": "quiet",
          "systemPromptTemplate": "Custom system prompt",
          "minValueThreshold": 0.7,
          "personas": [
            {
              "name": "Bot",
              "subtitle": "A bot",
              "prompt": "Be helpful.",
              "avatarTint": "red",
              "verbosity": "terse",
              "cadence": "rare",
              "evidencePolicy": "optional",
              "isEnabled": true,
              "webSearchEnabled": false
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        preset.apply(to: store)

        XCTAssertEqual(store.llmProvider, .openRouter)
        XCTAssertEqual(store.openRouterApiKey, "sk-or-v1-test")
        XCTAssertEqual(store.realtimeModel, "anthropic/claude-4-sonnet")
        XCTAssertEqual(store.sidecastTemperature, 0.5)
        XCTAssertEqual(store.sidecastMaxTokens, 500)
        XCTAssertEqual(store.sidecastIntensity, .quiet)
        XCTAssertEqual(store.sidecastSystemPrompt, "Custom system prompt")
        XCTAssertEqual(store.sidecastMinValueThreshold, 0.7)
        XCTAssertEqual(store.sidecastPersonas.count, 1)
        XCTAssertEqual(store.sidecastPersonas.first?.name, "Bot")
        XCTAssertEqual(store.sidecastPersonas.first?.avatarTint, .red)
        XCTAssertEqual(store.sidecastPersonas.first?.verbosity, .terse)
    }

    func testApplyOllamaPreset() throws {
        let store = makeStore()
        let json = """
        {
          "version": 1,
          "llmProvider": "ollama",
          "baseURL": "http://myserver:11434",
          "model": "llama3.2:8b"
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        preset.apply(to: store)

        XCTAssertEqual(store.llmProvider, .ollama)
        XCTAssertEqual(store.ollamaBaseURL, "http://myserver:11434")
        XCTAssertEqual(store.realtimeOllamaModel, "llama3.2:8b")
    }

    func testApplyOpenAICompatiblePreset() throws {
        let store = makeStore()
        let json = """
        {
          "version": 1,
          "llmProvider": "openai-compatible",
          "apiKey": "sk-custom",
          "baseURL": "http://localhost:4000",
          "model": "my-model"
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        preset.apply(to: store)

        XCTAssertEqual(store.llmProvider, .openAICompatible)
        XCTAssertEqual(store.openAILLMApiKey, "sk-custom")
        XCTAssertEqual(store.openAILLMBaseURL, "http://localhost:4000")
        XCTAssertEqual(store.openAILLMModel, "my-model")
    }

    func testApplyPresetWithoutProviderDoesNotOverwriteExisting() throws {
        let store = makeStore()
        store.llmProvider = .ollama
        store.ollamaBaseURL = "http://keep-this:11434"

        let json = """
        {
          "version": 1,
          "intensity": "lively",
          "personas": []
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        preset.apply(to: store)

        // Provider untouched
        XCTAssertEqual(store.llmProvider, .ollama)
        XCTAssertEqual(store.ollamaBaseURL, "http://keep-this:11434")
        // But intensity and personas were applied
        XCTAssertEqual(store.sidecastIntensity, .lively)
        XCTAssertTrue(store.sidecastPersonas.isEmpty)
    }

    // MARK: - Persona Mapping

    func testPersonaEmojiToSymbolMapping() throws {
        let json = """
        {
          "version": 1,
          "personas": [
            {
              "name": "Custom",
              "subtitle": "Test",
              "prompt": "Test",
              "avatarTint": "indigo",
              "avatarEmoji": "\\u26A1",
              "verbosity": "medium",
              "cadence": "active",
              "evidencePolicy": "preferred",
              "isEnabled": true,
              "webSearchEnabled": false
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        preset.apply(to: makeStore())

        let persona = preset.personas!.first!.toSidecastPersona()
        XCTAssertEqual(persona.avatarSymbol, "bolt.fill") // ⚡ maps to bolt.fill
        XCTAssertEqual(persona.avatarTint, .indigo)
        XCTAssertEqual(persona.verbosity, .medium)
        XCTAssertEqual(persona.cadence, .active)
        XCTAssertEqual(persona.evidencePolicy, .preferred)
    }

    func testPersonaUnknownEmojiFallsBackToNameMatch() throws {
        let json = """
        {
          "version": 1,
          "personas": [
            {
              "name": "The Archivist",
              "subtitle": "Test",
              "prompt": "Test",
              "avatarTint": "blue",
              "avatarEmoji": "🦄",
              "verbosity": "short",
              "cadence": "normal",
              "evidencePolicy": "optional",
              "isEnabled": true,
              "webSearchEnabled": false
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        let persona = preset.personas!.first!.toSidecastPersona()
        // Unknown emoji, but name contains "archiv" → books.vertical.fill
        XCTAssertEqual(persona.avatarSymbol, "books.vertical.fill")
    }

    func testPersonaNoEmojiNoNameMatchFallsBackToDefault() throws {
        let json = """
        {
          "version": 1,
          "personas": [
            {
              "name": "Mystery",
              "subtitle": "Test",
              "prompt": "Test",
              "avatarTint": "teal",
              "verbosity": "short",
              "cadence": "normal",
              "evidencePolicy": "optional",
              "isEnabled": true,
              "webSearchEnabled": false
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        let persona = preset.personas!.first!.toSidecastPersona()
        XCTAssertEqual(persona.avatarSymbol, "person.crop.circle.fill")
        XCTAssertEqual(persona.avatarTint, .teal)
    }

    func testUnknownTintFallsBackToBlue() throws {
        let json = """
        {
          "version": 1,
          "personas": [
            {
              "name": "Test",
              "subtitle": "Test",
              "prompt": "Test",
              "avatarTint": "magenta",
              "verbosity": "short",
              "cadence": "normal",
              "evidencePolicy": "optional",
              "isEnabled": true,
              "webSearchEnabled": false
            }
          ]
        }
        """
        let preset = try JSONDecoder().decode(SidecastPreset.self, from: Data(json.utf8))
        let persona = preset.personas!.first!.toSidecastPersona()
        XCTAssertEqual(persona.avatarTint, .blue)
    }
}
