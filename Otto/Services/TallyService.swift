import Foundation
import Security

/// Stores the user's Tally API key (`tly-…`) in the macOS Keychain and
/// surfaces a tiny presence-check used by the integration card and the
/// MCP-server injector. Tally hosts a remote MCP server at
/// `https://api.tally.so/mcp` that takes the key as a Bearer header —
/// once the key is set, every chat turn wires that server into the agent's
/// tool list.
///
/// API keys are sensitive (they grant full account access), so we use
/// Keychain rather than UserDefaults — matches the recent
/// ClaudeAuthService / CodexAuthService pattern for pasted API keys
/// rather than the older Notion / Todoist UserDefaults approach.
actor TallyService {
    static let shared = TallyService()

    private init() {}

    // MARK: - Public API

    nonisolated func apiKey() -> String? {
        Self.readAPIKey()
    }

    nonisolated func hasAPIKey() -> Bool {
        guard let key = apiKey() else { return false }
        return !key.isEmpty
    }

    /// Persists a user-pasted Tally API key. Empty / whitespace-only
    /// strings clear the entry instead.
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

    // MARK: - Keychain plumbing

    private static let apiKeyService = "com.otto.tally.apikey"
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
            NSLog("[Tally] API key SecItemAdd failed status=%d", Int(status))
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
