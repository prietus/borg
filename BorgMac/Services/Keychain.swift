import Foundation
import Security

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain returned an error (\(status))"
        case .encodingFailed:
            return "Could not encode the passphrase"
        }
    }
}

enum Keychain {
    private static let service = "com.carlos.BorgMac"

    static func setPassphrase(_ passphrase: String, for repoId: UUID) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repoId.uuidString,
        ]
        SecItemDelete(base as CFDictionary)

        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        var attrs = base
        attrs[kSecValueData as String] = data
        // No trusted-apps ACL. Using `kSecAttrAccessible` means any process
        // running as this user that queries the same service+account can
        // read the item freely once the keychain is unlocked. This matches
        // how most apps store secrets and — crucially — avoids the system
        // keychain password dialog that pops up when the binary's code
        // signature changes (every rebuild in ad-hoc signed dev builds,
        // and every launchd-spawned `--run-backup` invocation).
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Returns the stored passphrase without any biometric prompt.
    /// The Keychain item itself is protected by the user's login
    /// keychain (`kSecAttrAccessibleAfterFirstUnlock`), which is the
    /// real security layer — the Touch ID gate we used to have on top
    /// was pure UX theatre and was just nagging the user for every
    /// read. Kept `async` for source compatibility with call sites
    /// that awaited the old prompting variant.
    ///
    /// Also transparently migrates legacy items written with the old
    /// trusted-apps ACL by rewriting them without it.
    static func passphrase(for repoId: UUID, reason: String) async -> String? {
        guard let value = readPassphrase(for: repoId) else { return nil }
        try? setPassphrase(value, for: repoId)
        return value
    }

    /// Reads the passphrase without any biometric prompt. Used by scheduled
    /// backups (launchd) where no user is at the keyboard. After a
    /// successful read the item is transparently rewritten without the
    /// legacy trusted-apps ACL, so future reads stop triggering the
    /// "BorgMac wants to access your keychain" system dialog.
    static func unattendedPassphrase(for repoId: UUID) -> String? {
        guard let value = readPassphrase(for: repoId) else { return nil }
        try? setPassphrase(value, for: repoId)
        return value
    }

    /// Reads the passphrase without prompting. Used internally after successful auth.
    private static func readPassphrase(for repoId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repoId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// No-op kept for source compatibility with older call sites.
    /// The biometric gate was removed because it added prompts
    /// without adding real security — the Keychain items are
    /// already gated by the user's login keychain.
    static func forgetAuthentication() {}

    static func delete(repoId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repoId.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - BorgBase API token
    //
    // The BorgBase GraphQL API key is stored alongside the repo passphrases
    // but in a separate service namespace, without the biometric gate so that
    // repeated queries during a panel session don't keep prompting Touch ID.

    private static let borgBaseService = "com.carlos.BorgMac.BorgBase"
    private static let borgBaseAccount = "api-token"

    static func setBorgBaseToken(_ token: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBaseService,
            kSecAttrAccount as String: borgBaseAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func borgBaseToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBaseService,
            kSecAttrAccount as String: borgBaseAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Transparent migration: rewrite without the legacy trusted-apps ACL
        // so the next read doesn't trigger the system keychain dialog.
        try? setBorgBaseToken(str)
        return str
    }

    static func deleteBorgBaseToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBaseService,
            kSecAttrAccount as String: borgBaseAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - BorgBox tokens (per-server, keyed by server UUID)

    private static let borgBoxService = "com.carlos.BorgMac.BorgBox"

    static func setBorgBoxToken(_ token: String, for serverId: UUID) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxService,
            kSecAttrAccount as String: serverId.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func borgBoxToken(for serverId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxService,
            kSecAttrAccount as String: serverId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Transparent migration: see borgBaseToken().
        try? setBorgBoxToken(str, for: serverId)
        return str
    }

    static func deleteBorgBoxToken(for serverId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxService,
            kSecAttrAccount as String: serverId.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - BorgBox repo passphrases
    //
    // The borg passphrase for each BorgBox repo, persisted so that the panel
    // doesn't have to prompt the user every time they open a submenu (Check,
    // Prune, Compact, Archives). Keyed by `<serverUUID>.<repoName>` so the
    // same repo on two different servers gets independent entries.

    private static let borgBoxRepoPassService = "com.carlos.BorgMac.BorgBox.repo"

    private static func borgBoxRepoAccount(serverId: UUID, repo: String) -> String {
        "\(serverId.uuidString).\(repo)"
    }

    static func setBorgBoxRepoPassphrase(_ passphrase: String, serverId: UUID, repo: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxRepoPassService,
            kSecAttrAccount as String: borgBoxRepoAccount(serverId: serverId, repo: repo),
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func borgBoxRepoPassphrase(serverId: UUID, repo: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxRepoPassService,
            kSecAttrAccount as String: borgBoxRepoAccount(serverId: serverId, repo: repo),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Transparent migration: see borgBaseToken().
        try? setBorgBoxRepoPassphrase(str, serverId: serverId, repo: repo)
        return str
    }

    static func deleteBorgBoxRepoPassphrase(serverId: UUID, repo: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: borgBoxRepoPassService,
            kSecAttrAccount as String: borgBoxRepoAccount(serverId: serverId, repo: repo),
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - License (LemonSqueezy)
    //
    // Stores the license key, the LS instance id returned by /activate, and
    // the customer email. Kept in its own service namespace so a future
    // migration to a different billing provider doesn't collide with other
    // app secrets. Trial start date lives here too (not in UserDefaults) so
    // that reinstalling BorgMac doesn't reset the trial clock for a single
    // user on a single Mac.

    private static let licenseService = "com.carlos.BorgMac.License"
    private static let licenseKeyAccount = "license-key"
    private static let licenseInstanceAccount = "license-instance"
    private static let licenseEmailAccount = "license-email"
    private static let licenseCheckAccount = "license-last-check"
    private static let licenseTrialAccount = "license-trial-start"

    static func setLicense(key: String, instanceId: String, email: String) throws {
        try writeLicenseString(key, account: licenseKeyAccount)
        try writeLicenseString(instanceId, account: licenseInstanceAccount)
        try writeLicenseString(email, account: licenseEmailAccount)
    }

    static func license() -> StoredLicense? {
        guard let key = readLicenseString(account: licenseKeyAccount),
              let instanceId = readLicenseString(account: licenseInstanceAccount) else {
            return nil
        }
        let email = readLicenseString(account: licenseEmailAccount) ?? ""
        return StoredLicense(key: key, instanceId: instanceId, email: email)
    }

    static func deleteLicense() {
        for account in [licenseKeyAccount, licenseInstanceAccount, licenseEmailAccount, licenseCheckAccount] {
            deleteLicenseEntry(account: account)
        }
    }

    static func setLicenseLastCheck(_ date: Date) {
        let iso = ISO8601DateFormatter().string(from: date)
        try? writeLicenseString(iso, account: licenseCheckAccount)
    }

    static func licenseLastCheck() -> Date? {
        guard let s = readLicenseString(account: licenseCheckAccount) else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    static func setTrialStart(_ date: Date) {
        let iso = ISO8601DateFormatter().string(from: date)
        try? writeLicenseString(iso, account: licenseTrialAccount)
    }

    static func trialStart() -> Date? {
        guard let s = readLicenseString(account: licenseTrialAccount) else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func writeLicenseString(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: licenseService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    private static func readLicenseString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: licenseService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func deleteLicenseEntry(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: licenseService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct StoredLicense {
    let key: String
    let instanceId: String
    let email: String
}
