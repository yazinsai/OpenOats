import Foundation
import Security

struct AppSecretStore: Sendable {
    let loadValue: @Sendable (String) -> String?
    let saveValue: @Sendable (String, String) -> Void

    func load(key: String) -> String? {
        loadValue(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    static let keychain = AppSecretStore(
        loadValue: { KeychainHelper.load(key: $0) },
        saveValue: { key, value in
            KeychainHelper.save(key: key, value: value)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct SettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> SettingsStorage {
        SettingsStorage(
            defaults: defaults,
            secretStore: .keychain,
            defaultNotesDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/OpenOats"),
            runMigrations: true
        )
    }
}

/// Backward-compatible alias for existing test code.
typealias AppSettingsStorage = SettingsStorage

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.openoats.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func saveIfMissing(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
