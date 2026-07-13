import Foundation

/// Persists API keys in UserDefaults rather than the system Keychain.
///
/// This used to go through Keychain. The problem: this app is ad-hoc
/// signed (no paid Apple Developer ID yet), and an ad-hoc signature isn't
/// a stable identity across rebuilds — so macOS treats every rebuilt
/// binary as a different app asking to read a previous build's Keychain
/// item, and shows the "Eaon wants to use your confidential information
/// stored in… your keychain" system prompt. That's a bad, scary-looking
/// experience for something as low-stakes as an API key (not a bank
/// password), and it would resurface on *every* self-update. Plain
/// UserDefaults storage — the same mechanism the rest of the app already
/// uses for everything else — has no such prompt, ever.
enum APIKeyStore {
    private static let defaults = UserDefaults.standard
    private static let primaryAccount = "eaon-api-key"
    private static let legacyPrimaryAccount = "aquadevs-api-key"
    private static let legacyAccountMigrationDoneKey = "legacy_api_key_account_migration_done_v1"

    /// One-shot: carries a key already saved under the old account name
    /// forward to the new one, now that the storage key itself no longer
    /// mentions "aquadevs" — copies rather than deletes the old value, so
    /// running this more than once (or a downgrade) can't lose a key.
    static func migrateLegacyAccountNameIfNeeded() {
        guard !defaults.bool(forKey: legacyAccountMigrationDoneKey) else { return }
        defer { defaults.set(true, forKey: legacyAccountMigrationDoneKey) }

        guard loadAPIKey(forAccount: primaryAccount) == nil,
              let legacyValue = loadAPIKey(forAccount: legacyPrimaryAccount) else { return }
        try? saveAPIKey(legacyValue, forAccount: primaryAccount)
    }

    static func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, forAccount: primaryAccount)
    }

    static func loadAPIKey() -> String? {
        loadAPIKey(forAccount: primaryAccount)
    }

    static func deleteAPIKey() {
        deleteAPIKey(forAccount: primaryAccount)
    }

    static var hasAPIKey: Bool {
        loadAPIKey() != nil
    }

    // MARK: - Multi-account storage (custom/BYOK providers each get their own account)

    static func saveAPIKey(_ value: String, forAccount account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey(forAccount: account)
            return
        }
        defaults.set(trimmed, forKey: storageKey(for: account))
    }

    static func loadAPIKey(forAccount account: String) -> String? {
        guard let value = defaults.string(forKey: storageKey(for: account)), !value.isEmpty else { return nil }
        return value
    }

    static func deleteAPIKey(forAccount account: String) {
        defaults.removeObject(forKey: storageKey(for: account))
    }

    private static func storageKey(for account: String) -> String {
        "api_key_\(account)"
    }
}
