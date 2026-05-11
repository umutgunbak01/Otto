import Foundation

/// Reads Codex CLI's OAuth credentials. Source of truth is `~/.codex/auth.json`
/// (mode 600) which the `codex` CLI writes when the user signs in. The CLI
/// itself owns token refresh — running `codex exec` will rotate tokens
/// transparently — so this service is read-only.
///
/// Mirrors the role of `ClaudeAuthService` for the parallel Codex backend.
actor CodexAuthService {
    static let shared = CodexAuthService()

    private init() {}

    // MARK: - Credential Types

    /// Top-level shape of `~/.codex/auth.json`.
    struct Credentials: Codable {
        let authMode: String?
        let openAIAPIKey: String?
        let tokens: Tokens?
        let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
            case lastRefresh = "last_refresh"
        }
    }

    struct Tokens: Codable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountId = "account_id"
        }
    }

    enum AuthError: LocalizedError {
        case notSignedIn
        case parseError(String)
        case refreshFailed(Int, String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to Codex. Open the Codex app or run `codex login` first."
            case .parseError(let msg):
                return "Failed to read Codex credentials: \(msg)"
            case .refreshFailed(let code, let msg):
                return "Codex token refresh failed (\(code)): \(msg)"
            case .writeFailed(let msg):
                return "Failed to save refreshed Codex token: \(msg)"
            }
        }
    }

    // MARK: - OAuth refresh constants
    // Endpoint + client ID are baked into the Codex CLI binary (string-grepped
    // from `/Applications/Codex.app/Contents/Resources/codex` — the client ID
    // identifies the Codex CLI app to OpenAI's OAuth server, not a per-user
    // secret, so it's safe to commit). If OpenAI ever rotates either, the
    // codex CLI release notes are the source of truth.
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    // MARK: - Public API

    /// Returns the current OAuth access token. The Codex CLI owns rotation —
    /// we just read whatever is on disk. Callers shelling out to the CLI
    /// don't need this; it's exposed for any future direct-API path.
    func getAccessToken() async throws -> String {
        let creds = try Self.loadCredentials()
        if let key = creds.openAIAPIKey, !key.isEmpty {
            return key
        }
        guard let token = creds.tokens?.accessToken, !token.isEmpty else {
            throw AuthError.notSignedIn
        }
        return token
    }

    /// Force-refresh the OAuth tokens via OpenAI's token endpoint and write
    /// the new bundle back to `~/.codex/auth.json` so the Codex CLI picks it
    /// up on its next invocation. Same role as `ClaudeAuthService.refreshAccessToken`:
    /// useful after a plan upgrade where the old access token may still be
    /// bound to the old rate-limit tier.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        let creds = try Self.loadCredentials()
        guard let refreshToken = creds.tokens?.refreshToken, !refreshToken.isEmpty else {
            throw AuthError.notSignedIn
        }

        // OpenAI's /oauth/token expects form-encoded grant_type=refresh_token
        // (verified via the codex binary's strings — Content-Type:
        // application/x-www-form-urlencoded).
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientId)
        ]
        let body = (form.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("codex-cli (Otto)", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.refreshFailed(0, "no response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw AuthError.refreshFailed(http.statusCode, msg)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = obj["access_token"] as? String, !newAccessToken.isEmpty
        else {
            throw AuthError.refreshFailed(200, "unexpected response shape")
        }
        let newRefreshToken = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let newIdToken = obj["id_token"] as? String

        try Self.writeRefreshedTokens(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            idToken: newIdToken
        )
        return newAccessToken
    }

    /// Merge new OAuth tokens back into `~/.codex/auth.json`, preserving
    /// fields we don't touch (account_id, auth_mode, anything OpenAI adds
    /// later). Bumps `last_refresh` to the current UTC timestamp so the
    /// Codex CLI sees a fresh write.
    private nonisolated static func writeRefreshedTokens(
        accessToken: String,
        refreshToken: String,
        idToken: String?
    ) throws {
        let existing = (try? Data(contentsOf: authFileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        var root = existing
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = isoFmt.string(from: Date())

        do {
            let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // Preserve mode 0600 by writing through FileManager (atomic) and
            // re-applying permissions.
            try updated.write(to: authFileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authFileURL.path
            )
        } catch {
            throw AuthError.writeFailed(error.localizedDescription)
        }
    }

    /// Non-blocking readiness check used by the Settings UI to show the
    /// sign-in badge.
    nonisolated func isSignedIn() -> Bool {
        guard let creds = try? Self.loadCredentials() else { return false }
        if creds.openAIAPIKey?.isEmpty == false { return true }
        return creds.tokens?.accessToken?.isEmpty == false
    }

    /// The ChatGPT account UUID the CLI stored at last login. Parallels
    /// `ClaudeAuthService.loadIdentity()` so future telemetry / billing
    /// routing can pick it up without re-parsing the file.
    nonisolated static func loadIdentity() -> String? {
        (try? loadCredentials())?.tokens?.accountId
    }

    // MARK: - Loading

    private static let authFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    private nonisolated static func loadCredentials() throws -> Credentials {
        guard FileManager.default.fileExists(atPath: authFileURL.path),
              let data = try? Data(contentsOf: authFileURL) else {
            throw AuthError.notSignedIn
        }
        do {
            return try JSONDecoder().decode(Credentials.self, from: data)
        } catch {
            throw AuthError.parseError(error.localizedDescription)
        }
    }
}
