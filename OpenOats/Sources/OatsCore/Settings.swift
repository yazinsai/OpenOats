import Foundation
import Security

/// The user's preferences that Processing and the Recorder read. API keys are not here (Keychain).
public struct Settings: Codable, Sendable, Equatable {
    public var notesFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/OpenOats")
    /// BCP 47 code; nil = the system language.
    public var language: String?
    public var vocabulary: [String] = []
    public var transcription = TranscriptionConfig(type: .onDevice)
    public var notes = NotesConfig(type: .none)
    /// nil = `NotesWriter.defaultPrompt` (Reset sets it back to nil).
    public var notesPrompt: String?
    public var deleteAudioAfterProcessing = false
    /// Meeting detection: a "Record this meeting?" prompt when a Call starts.
    public var askToRecordCalls = true
    /// `CallApp` ids the user said not to ask about again.
    public var ignoredCallApps: [String] = []
    /// Name Meetings after the calendar event they happened in. nil until the user chooses, so the app can offer it once.
    public var titleFromCalendar: Bool?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        notesFolder = try c.decodeIfPresent(URL.self, forKey: .notesFolder) ?? d.notesFolder
        language = try c.decodeIfPresent(String.self, forKey: .language)
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        transcription = try c.decodeIfPresent(TranscriptionConfig.self, forKey: .transcription) ?? d.transcription
        notes = try c.decodeIfPresent(NotesConfig.self, forKey: .notes) ?? d.notes
        notesPrompt = try c.decodeIfPresent(String.self, forKey: .notesPrompt)
        deleteAudioAfterProcessing = try c.decodeIfPresent(Bool.self, forKey: .deleteAudioAfterProcessing) ?? false
        askToRecordCalls = try c.decodeIfPresent(Bool.self, forKey: .askToRecordCalls) ?? true
        ignoredCallApps = try c.decodeIfPresent([String].self, forKey: .ignoredCallApps) ?? []
        titleFromCalendar = try c.decodeIfPresent(Bool.self, forKey: .titleFromCalendar)
    }

    /// The language a new Meeting is recorded in.
    public var meetingLanguage: String {
        language ?? Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
    }
}

/// Where API keys live; the Keychain in the app, an in-memory fake in tests.
public protocol SecretStore: Sendable {
    func secret(_ account: String) -> String?
    func setSecret(_ value: String?, _ account: String)
}

public struct Keychain: SecretStore {
    public var service = "com.openoats.app"
    public init() {
        if let suite = ProcessInfo.processInfo.environment["OATS_DEFAULTS_SUITE"] { service += ".\(suite)" }
    }

    public func secret(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, _ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var query = base(account)
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// Loads and saves `Settings` (shared by the app and the `oats` CLI) and turns them into backends.
public struct SettingsStore: @unchecked Sendable {
    public static let domain = "com.openoats.app"
    static let key = "v2.settings"
    public let defaults: UserDefaults
    public let secrets: any SecretStore
    public let makers: BackendMakers

    /// `OATS_DEFAULTS_SUITE` (UI tests, manual runs) keeps the app and its `oats` child off the real settings domain.
    public init(defaults: UserDefaults? = nil, secrets: any SecretStore = Keychain(), makers: BackendMakers = .builtIn) {
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["OATS_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:))
            ?? (Bundle.main.bundleIdentifier == Self.domain ? .standard : UserDefaults(suiteName: Self.domain)!)
        self.secrets = secrets
        self.makers = makers
    }

    public func load() -> Settings {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    public func save(_ settings: Settings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }

    /// Keys are kept per Preset (or per type for a custom address), so switching Presets keeps each key.
    public static func keyAccount<K>(for config: BackendConfig<K>) -> String {
        "v2.\(K.self == NotesBackendType.self ? "notes" : "transcription").\(config.preset ?? "\(config.type)")"
    }

    public func apiKey<K>(for config: BackendConfig<K>) -> String? { secrets.secret(Self.keyAccount(for: config)) }
    public func setAPIKey<K>(_ key: String?, for config: BackendConfig<K>) { secrets.setSecret(key, Self.keyAccount(for: config)) }

    public func transcriptionBackend(_ config: TranscriptionConfig) -> any TranscriptionBackend {
        makers.transcription[config.type]?(setup(config, Preset.all)) ?? UnavailableBackend(name: config.type.rawValue)
    }

    /// nil for the `none` type (the Notes step is skipped).
    public func notesBackend(_ config: NotesConfig) -> (any NotesBackend)? {
        guard config.type != .none else { return nil }
        return makers.notes[config.type]?(setup(config, Preset.all)) ?? UnavailableBackend(name: config.type.rawValue)
    }

    /// Onboarding shows until the recording-consent acknowledgement is stored.
    public var consentAcknowledged: Bool {
        get { defaults.object(forKey: "v2.consentAcknowledged") != nil }
        nonmutating set { defaults.set(newValue ? Date() : nil, forKey: "v2.consentAcknowledged") }
    }

    /// What `ProcessingQueue` and `oats process` run with, from the saved settings.
    public func processingOptions() -> ProcessingOptions {
        let s = load()
        return ProcessingOptions(
            transcription: transcriptionBackend(s.transcription), notes: notesBackend(s.notes),
            notesStep: NotesWriter.step(prompt: s.notesPrompt ?? NotesWriter.defaultPrompt, vocabulary: s.vocabulary),
            notesFolder: s.notesFolder, keepAudio: !s.deleteAudioAfterProcessing
        )
    }

    func setup<K>(_ config: BackendConfig<K>, _ presets: [Preset<K>]) -> BackendSetup<K> {
        let preset = presets.first { $0.name == config.preset && $0.type == config.type }
        let address = config.address ?? preset?.address
        let model = config.model.flatMap { $0.isEmpty ? nil : $0 } ?? preset?.model
        return BackendSetup(type: config.type, address: address, model: model, apiKey: apiKey(for: config),
                            contextTokens: BackendSetup<K>.contextTokens(address))
    }
}
