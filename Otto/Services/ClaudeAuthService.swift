import Foundation
import Security

/// Tracks whether Otto can talk to the Anthropic backend, via either of two
/// in-bounds paths:
///
/// 1. **Claude Code CLI login** — the user ran `claude` in Terminal and the
///    CLI stored its own OAuth credentials. Otto never reads or modifies
///    those credentials; it only checks that the Keychain entry / legacy
///    JSON file exists, so the Settings UI can show a sign-in badge. The
///    `claude` subprocess handles its own token rotation.
///
/// 2. **User-pasted Anthropic API key** — stored in this app's own Keychain
///    entry (`com.otto.anthropic.apikey`) and passed to the `claude`
///    subprocess via the `ANTHROPIC_API_KEY` env var. Billed against the
///    user's Anthropic API account, not their Claude subscription.
///
/// When both are configured, the API key wins (`effectiveAuthMode`).
actor ClaudeAuthService {
    static let shared = ClaudeAuthService()

    private init() {}

    /// Where the user's auth is currently coming from. The CLI subprocess
    /// reads from its own store regardless; this only governs whether we
    /// inject `ANTHROPIC_API_KEY` and what status copy to show.
    enum AuthMode {
        case apiKey
        case cliLogin
        case none
    }

    // MARK: - Sign-in status (CLI login path)

    /// True iff the `claude` CLI has stored credentials we can detect.
    /// Checks the Keychain entry the CLI writes (`Claude Code-credentials`)
    /// and falls back to the legacy `~/.claude/.credentials.json` file.
    /// Does **not** read the token contents — only the entry's presence.
    nonisolated func isCLISignedIn() -> Bool {
        if Self.keychainItemExists() { return true }
        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
            .path
        return FileManager.default.fileExists(atPath: legacyPath)
    }

    /// Resolves which auth path Otto should announce. API key wins when set
    /// because that's what gets injected into the subprocess env var.
    nonisolated func effectiveAuthMode() -> AuthMode {
        if apiKey() != nil { return .apiKey }
        if isCLISignedIn() { return .cliLogin }
        return .none
    }

    // MARK: - API key (Otto-managed Keychain)

    /// Returns the stored Anthropic API key, or nil if none is set.
    nonisolated func apiKey() -> String? {
        Self.readAPIKey()
    }

    /// Persists a user-pasted Anthropic API key. Empty / whitespace-only
    /// strings clear the entry instead. Returns true on success.
    @discardableResult
    nonisolated func setAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearAPIKey()
            return true
        }
        return Self.writeAPIKey(trimmed)
    }

    /// Removes the stored API key (if any).
    nonisolated func clearAPIKey() {
        Self.deleteAPIKey()
    }

    // MARK: - Keychain plumbing

    private static let apiKeyService = "com.otto.anthropic.apikey"
    private static let apiKeyAccount = "default"
    private static let cliKeychainService = "Claude Code-credentials"

    /// Probe for the CLI's Keychain entry without copying the secret. We pass
    /// `kSecMatchLimitOne` and read no attributes — Keychain returns
    /// `errSecSuccess` when the item exists and `errSecItemNotFound` when it
    /// doesn't, which is all we need.
    private static func keychainItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cliKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    private static func writeAPIKey(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        deleteAPIKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: apiKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Claude] API key SecItemAdd failed status=%d", Int(status))
            return false
        }
        return true
    }

    private static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: apiKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
