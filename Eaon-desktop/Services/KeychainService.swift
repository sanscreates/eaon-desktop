import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Could not save API key to Keychain (status \(status))."
        case .readFailed(let status):
            return "Could not read API key from Keychain (status \(status))."
        }
    }
}

enum KeychainService {
    private static let service = "com.aquachat.api"
    private static let account = "aquadevs-api-key"
    private static let legacyUserDefaultsKey = "apiKey"

    /// One-time migration from older builds that stored the key in UserDefaults.
    static func migrateLegacyKeyIfNeeded() {
        guard loadAPIKey() == nil,
              let legacy = UserDefaults.standard.string(forKey: legacyUserDefaultsKey),
              !legacy.isEmpty else { return }

        try? saveAPIKey(legacy)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
    }

    static func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, forAccount: account)
    }

    static func loadAPIKey() -> String? {
        loadAPIKey(forAccount: account)
    }

    static func deleteAPIKey() {
        deleteAPIKey(forAccount: account)
    }

    static var hasAPIKey: Bool {
        loadAPIKey() != nil
    }

    // MARK: - Multi-account storage (custom/BYOK providers each get their own account)

    static func saveAPIKey(_ key: String, forAccount account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(forAccount: account)
            return
        }

        let data = Data(trimmed.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func loadAPIKey(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func deleteAPIKey(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
