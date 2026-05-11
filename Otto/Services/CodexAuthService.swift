import Foundation
import Security

/// Tracks whether Otto can talk to the OpenAI backend, via either of two
/// in-bounds paths:
///
/// 1. **Codex CLI login** — the user ran `codex login` (or opened the Codex
///    desktop app) and the CLI wrote credentials to `~/.codex/auth.json`.
///    Otto never reads or modifies that file; it only checks the file's
///    presence so the Settings UI can show a sign-in badge. The `codex`
///    subprocess handles its own token rotation.
///
/// 2. **User-pasted OpenAI API key** — stored in this app's own Keychain
///    entry (`com.otto.openai.apikey`) and passed to the `codex`
///    subprocess via the `OPENAI_API_KEY` env var. Billed against the
///    user's OpenAI API account, not their ChatGPT subscription.
///
/// When both are configured, the API key wins (`effectiveAuthMode`).
///
/// Mirrors the shape of `ClaudeAuthService` for the parallel backend.
actor CodexAuthService {
    static let shared = CodexAuthService()

    private init() {}

    enum AuthMode {
        case apiKey
        case cliLogin
        case none
    }

    // MARK: - Sign-in status (CLI login path)

    /// True iff `~/.codex/auth.json` exists. We don't parse its contents.
    nonisolated func isCLISignedIn() -> Bool {
        FileManager.default.fileExists(atPath: Self.authFileURL.path)
    }

    nonisolated func effectiveAuthMode() -> AuthMode {
        if apiKey() != nil { return .apiKey }
        if isCLISignedIn() { return .cliLogin }
        return .none
    }

    // MARK: - API key (Otto-managed Keychain)

    nonisolated func apiKey() -> String? {
        Self.readAPIKey()
    }

    @discardableResult
    nonisolated func setAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearAPIKey()
            return true
        }
        return Self.writeAPIKey(trimmed)
    }

    nonisolated func clearAPIKey() {
        Self.deleteAPIKey()
    }

    // MARK: - Storage paths

    private static let authFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    private static let apiKeyService = "com.otto.openai.apikey"
    private static let apiKeyAccount = "default"

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
            NSLog("[Codex] API key SecItemAdd failed status=%d", Int(status))
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
