import Foundation

/// One-time import of 1.x settings and API keys (1.x defaults share the `com.openoats.app` domain and Keychain service).
/// 1.x data is only read: its defaults, Keychain items and session JSONL files are left as they are.
public enum Migration {
    /// Runs once, before anything saves v2 settings: the saved v2 settings are the marker. Returns true if it ran.
    @discardableResult
    public static func runIfNeeded(_ store: SettingsStore) -> Bool {
        let old = store.defaults, secrets = store.secrets
        guard old.object(forKey: SettingsStore.key) == nil else { return false }
        var s = Settings()
        func string(_ key: String) -> String? { old.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }

        if let path = string("notesFolderPath") {
            s.notesFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        s.language = string("transcriptionLocale").flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        // 1.x lines are `Term` or `Term: alias, alias`; v2 Vocabulary is the terms.
        s.vocabulary = (string("transcriptionCustomVocabulary") ?? "").split(separator: "\n").compactMap {
            let term = $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return term.isEmpty ? nil : term
        }
        if old.object(forKey: "saveAudioRecording") != nil { s.deleteAudioAfterProcessing = !old.bool(forKey: "saveAudioRecording") }

        // Every 1.x key with a v2 home moves, so switching Presets later finds it.
        for (account, v2) in keyAccounts {
            if let key = secrets.secret(account), !key.isEmpty, secrets.secret(v2) == nil { secrets.setSecret(key, v2) }
        }

        // Notes backend: the 1.x LLM provider's Preset, keeping a custom model or address; none without a needed key.
        let provider = string("llmProvider") ?? "openRouter"
        if let p = providers[provider] {
            var config = p.preset.map { notesPreset($0).config } ?? NotesConfig(type: .openAICompatible, address: "http://localhost:4000")
            if let address = p.addressKey.flatMap(string) { config.address = address }
            if let model = string(p.modelKey) { config.model = model }
            let needsKey = p.preset.map { notesPreset($0).needsKey } ?? false
            if !needsKey || store.apiKey(for: config) != nil { s.notes = config }
        }

        // Transcription backend: v2 Processing is batch, so the batch model wins when 1.x used it.
        let model = old.bool(forKey: "enableBatchRetranscription") ? string("batchTranscriptionModel") : string("transcriptionModel")
        if let name = ["assemblyAI": "AssemblyAI", "elevenLabsScribe": "ElevenLabs"][model ?? ""],
           case let config = transcriptionPreset(name).config, store.apiKey(for: config) != nil {
            s.transcription = config
        } // Parakeet, Whisper, Qwen3 and Cohere Arabic: on-device (it picks Parakeet v3 or Whisper by language).

        store.save(s)
        return true
    }

    static func notesPreset(_ name: String) -> Preset<NotesBackendType> { Preset<NotesBackendType>.all.first { $0.name == name }! }
    static func transcriptionPreset(_ name: String) -> Preset<TranscriptionBackendType> {
        Preset<TranscriptionBackendType>.all.first { $0.name == name }!
    }

    /// 1.x Keychain account → v2 account.
    static let keyAccounts: [String: String] = {
        var map = ["openAILLMApiKey": SettingsStore.keyAccount(for: NotesConfig(type: .openAICompatible))]
        for (account, name) in ["openRouterApiKey": "OpenRouter", "requestyApiKey": "Requesty", "openAIApiKey": "OpenAI",
                                "anthropicApiKey": "Anthropic", "lmStudioApiKey": "LM Studio"] {
            map[account] = SettingsStore.keyAccount(for: notesPreset(name).config)
        }
        for (account, name) in ["assemblyAIApiKey": "AssemblyAI", "elevenLabsApiKey": "ElevenLabs"] {
            map[account] = SettingsStore.keyAccount(for: transcriptionPreset(name).config)
        }
        return map
    }()

    /// 1.x `llmProvider` raw value → v2 Preset (nil = custom OpenAI-compatible) and its 1.x defaults keys.
    static let providers: [String: (preset: String?, modelKey: String, addressKey: String?)] = [
        "openRouter": ("OpenRouter", "selectedModel", nil), "requesty": ("Requesty", "requestyModel", "requestyBaseURL"),
        "openAI": ("OpenAI", "openAIModel", "openAIBaseURL"), "anthropic": ("Anthropic", "anthropicModel", "anthropicBaseURL"),
        "ollama": ("Ollama", "ollamaLLMModel", "ollamaBaseURL"), "lmStudio": ("LM Studio", "lmStudioModel", "lmStudioBaseURL"),
        "mlx": ("MLX", "mlxModel", "mlxBaseURL"), "openAICompatible": (nil, "openAILLMModel", "openAILLMBaseURL"),
    ]
}
