import Foundation
import Security

/// Reads Claude Code's OAuth credentials and provides a Bearer token for the
/// Anthropic Messages API. Source of truth is the macOS Keychain entry that
/// `claude` writes under service "Claude Code-credentials"; legacy JSON at
/// ~/.claude/.credentials.json is supported as a fallback.
actor ClaudeAuthService {
    static let shared = ClaudeAuthService()

    private init() {}

    // MARK: - Credential Types

    struct Credentials: Codable {
        let claudeAiOauth: OAuthToken
    }

    struct OAuthToken: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?  // Unix milliseconds
    }

    enum AuthError: LocalizedError {
        case notSignedIn
        case parseError(String)
        case refreshFailed(Int, String)
        case keychainWriteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to Claude Code. Run `claude` in the terminal first."
            case .parseError(let msg):
                return "Failed to read Claude Code credentials: \(msg)"
            case .refreshFailed(let code, let msg):
                return "Token refresh failed (\(code)): \(msg)"
            case .keychainWriteFailed(let status):
                return "Failed to save refreshed token to Keychain (status \(status))."
            }
        }
    }

    // MARK: - Claude Code OAuth constants
    // The official Claude Code CLI's client ID, extracted from the shipped
    // CLI binary's constants block. This identifies the CLI app to Anthropic's
    // OAuth server — it is not a per-user secret and is safe to commit. Per-user
    // tokens are stored in the macOS Keychain under "Claude Code-credentials".
    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// OAuth token endpoint (access + refresh exchange, production).
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Default scopes the CLI requests on refresh — match what's stored in Keychain.
    private static let defaultScopes = [
        "user:inference",
        "user:profile",
        "user:file_upload",
        "user:mcp_servers",
        "user:sessions:claude_code"
    ]

    // MARK: - Public API

    /// Returns the current OAuth access token. Claude Code CLI owns token rotation —
    /// we just read whatever it has persisted. On 401 from the API, caller should
    /// prompt the user to run `claude`.
    func getAccessToken() async throws -> String {
        let creds = try loadCredentials()
        return creds.claudeAiOauth.accessToken
    }

    /// Force a token refresh using the stored refresh_token. Writes the new tokens
    /// back to the Keychain entry so the CLI picks them up too. Returns the fresh
    /// access token. Useful when the user upgrades their plan — the existing access
    /// token may still be bound to the old rate-limit tier until a new one is issued.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        let creds = try loadCredentials()
        guard let refreshToken = creds.claudeAiOauth.refreshToken else {
            throw AuthError.notSignedIn
        }

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientId,
            "scope": Self.defaultScopes.joined(separator: " ")
        ]

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-cli/2.1.114 (external, cli)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.refreshFailed(0, "no response") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw AuthError.refreshFailed(http.statusCode, msg)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = obj["access_token"] as? String
        else {
            throw AuthError.refreshFailed(200, "unexpected response shape")
        }

        // Build the full credentials blob in the exact shape the CLI writes to Keychain.
        let newRefreshToken = (obj["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000

        // Preserve any existing fields (scopes, subscriptionType, rateLimitTier) by
        // merging into the original JSON. Falls back to a minimal blob if that fails.
        let originalBlob = try Self.readCredentialBlob() ?? Data()
        var merged: [String: Any] = [:]
        if let root = try? JSONSerialization.jsonObject(with: originalBlob) as? [String: Any],
           let existingOauth = root["claudeAiOauth"] as? [String: Any] {
            merged = existingOauth
        }
        merged["accessToken"] = newAccessToken
        merged["refreshToken"] = newRefreshToken
        merged["expiresAt"] = expiresAtMs

        // After a refresh the server may return an updated subscription/tier scope in
        // the `scope` response field — that's what actually picks up plan upgrades.
        if let newScope = obj["scope"] as? String {
            merged["scopes"] = newScope.split(separator: " ").map(String.init)
        }

        let outerBlob: [String: Any] = ["claudeAiOauth": merged]
        let blobData = try JSONSerialization.data(withJSONObject: outerBlob)
        try Self.writeCredentialBlob(blobData)

        return newAccessToken
    }

    /// Non-blocking readiness check used by Settings.
    nonisolated func isSignedIn() -> Bool {
        (try? Self.readCredentialBlob()) != nil
    }

    // MARK: - CLI identity (for Messages API metadata.user_id)

    struct ClaudeCodeIdentity {
        let deviceId: String     // ~/.claude.json → userID
        let accountUuid: String  // ~/.claude.json → oauthAccount.accountUuid
    }

    /// Reads the two IDs the CLI includes in `metadata.user_id` on every /v1/messages
    /// POST. Anthropic's subscription rate-limiter appears to key off `account_uuid`
    /// to route requests into the right plan bucket — without this, Otto falls back
    /// to standard pay-as-you-go limits even with a valid OAuth token.
    ///
    /// Returns nil if `~/.claude.json` isn't readable or either field is missing;
    /// callers should treat that as "send request with no metadata" (same as before).
    nonisolated static func loadIdentity() -> ClaudeCodeIdentity? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let deviceId = (root["userID"] as? String) ?? ""
        let oauth = (root["oauthAccount"] as? [String: Any]) ?? [:]
        let accountUuid = (oauth["accountUuid"] as? String) ?? ""
        guard !deviceId.isEmpty, !accountUuid.isEmpty else { return nil }
        return ClaudeCodeIdentity(deviceId: deviceId, accountUuid: accountUuid)
    }

    // MARK: - Loading

    private func loadCredentials() throws -> Credentials {
        guard let data = try Self.readCredentialBlob() else {
            throw AuthError.notSignedIn
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Credentials.self, from: data)
        } catch {
            throw AuthError.parseError(error.localizedDescription)
        }
    }

    /// Returns the raw credentials JSON blob. Tries Keychain first (current location),
    /// falls back to ~/.claude/.credentials.json (legacy). Returns nil if neither exists.
    nonisolated static func readCredentialBlob() throws -> Data? {
        if let fromKeychain = readFromKeychain() {
            return fromKeychain
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
            .path
        if FileManager.default.fileExists(atPath: path) {
            return FileManager.default.contents(atPath: path)
        }
        return nil
    }

    private nonisolated static func readFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Write credentials back to the same source we read from. Tries to update the
    /// existing Keychain item first (so the CLI sees our refresh); falls back to
    /// adding a new item, or writing the JSON file, as needed.
    nonisolated static func writeCredentialBlob(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials"
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            // Keychain blocked us — fall back to the legacy JSON path so at least
            // Otto itself can still use the refreshed token next launch.
            let fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                throw AuthError.keychainWriteFailed(status)
            }
        }
    }
}
