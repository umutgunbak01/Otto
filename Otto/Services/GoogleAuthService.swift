import Foundation
import AuthenticationServices
import Security
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Google Auth Service

final class GoogleAuthService: @unchecked Sendable {
    static let shared = GoogleAuthService()

    // OAuth Configuration — users supply their own Google OAuth Client ID
    // (Desktop application type, created in Google Cloud Console → Credentials)
    // via Settings. Stored in UserDefaults under `google_oauth_client_id`.
    var clientId: String {
        get { UserDefaults.standard.string(forKey: "google_oauth_client_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "google_oauth_client_id") }
    }

    var hasClientId: Bool {
        !clientId.isEmpty
    }

    // Scopes are computed at OAuth-URL-build time so additional integrations
    // (e.g. Drive) can opt the user into extra grants without rewriting the
    // Gmail/Calendar OAuth path. The user always gets gmail.readonly and
    // calendar.readonly; Drive scopes are added when `driveEnabled` is on.
    private static let baseScopes: [String] = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly"
    ]
    private static let driveScopes: [String] = [
        // Google's Drive MCP server requires both of these (the readonly grant
        // covers list/search/read; drive.file lets the agent create files in
        // folders Otto has been granted access to).
        // See: https://developers.google.com/workspace/drive/api/guides/configure-mcp-server
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/drive.file"
    ]

    private var requestedScopes: String {
        var scopes = Self.baseScopes
        if driveEnabled {
            scopes.append(contentsOf: Self.driveScopes)
        }
        return scopes.joined(separator: " ")
    }

    /// True iff the user has opted into Drive in Integrations and successfully
    /// re-consented to the expanded scope set. Best-effort flag — flipped on
    /// after `reauthorize()` returns a fresh token; flipped off on Disconnect
    /// Drive. We don't introspect the actual token's scopes (Google doesn't
    /// reliably echo them back); the cost of a wrong flag is a 401 from the
    /// Drive MCP server, surfaced as a tool-error chip in chat.
    var driveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "google_drive_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "google_drive_enabled") }
    }

    /// Compact predicate for callers (IntegrationsView card, system-prompt
    /// gate, MCP-server injector). Requires both an OAuth token AND the
    /// `driveEnabled` flag — if either is missing, Drive doesn't get wired
    /// into the chat.
    func hasDriveScopes() -> Bool {
        driveEnabled && isAuthenticated()
    }

    // For iOS/Desktop client types, use reverse client ID as redirect URI
    private var redirectUri: String {
        // Reverse the client ID: com.googleusercontent.apps.CLIENT_ID_PREFIX
        let prefix = clientId.split(separator: ".").first ?? ""
        return "com.googleusercontent.apps.\(prefix):/oauth2callback"
    }

    private var callbackURLScheme: String {
        let prefix = clientId.split(separator: ".").first ?? ""
        return "com.googleusercontent.apps.\(prefix)"
    }

    // Keychain keys (account names) and the service identifier they live under.
    // GenericPassword items are uniquely identified by the (service, account)
    // pair on macOS — without an explicit service the items can collide with
    // arbitrary other entries the user has, which is what was causing
    // tokeninfo to read back garbage and return "Invalid Value".
    private let accessTokenKey = "com.otto.gmail.accessToken"
    private let refreshTokenKey = "com.otto.gmail.refreshToken"
    private let tokenExpiryKey = "com.otto.gmail.tokenExpiry"
    private let keychainService = "com.otto.GoogleAuth"

    private let lock = NSLock()

    private init() {
        // One-time cleanup: an earlier build wrote these accounts WITHOUT a
        // service attribute, so the slot can hold a stale value belonging to
        // a different keychain entry. Wipe both the legacy slot and any
        // partially-written items in the new slot, so the next OAuth round
        // starts from zero. Idempotent — safe to run on every launch.
        Self.purgeLegacyKeychainItems(accounts: [accessTokenKey, refreshTokenKey])
    }

    /// Delete any GenericPassword item with the given `account` and an empty
    /// service. These were created by the older code that didn't set
    /// `kSecAttrService` and can shadow / confuse the real entries.
    private static func purgeLegacyKeychainItems(accounts: [String]) {
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account
            ]
            // SecItemDelete with no service deletes ALL entries with this
            // account regardless of service — that's what we want here, since
            // we're re-keying everything under the new service identifier on
            // the next OAuth flow anyway.
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Token Management

    func getAccessToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return getKeychainItem(key: accessTokenKey)
    }

    func getRefreshToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return getKeychainItem(key: refreshTokenKey)
    }

    func isAuthenticated() -> Bool {
        return getAccessToken() != nil
    }

    func setTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
        lock.lock()
        defer { lock.unlock() }

        setKeychainItem(key: accessTokenKey, value: accessToken)
        if let refreshToken = refreshToken {
            setKeychainItem(key: refreshTokenKey, value: refreshToken)
        }
        // Store expiry time
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        UserDefaults.standard.set(expiry, forKey: tokenExpiryKey)
    }

    func signOut() {
        lock.lock()
        defer { lock.unlock() }

        deleteKeychainItem(key: accessTokenKey)
        deleteKeychainItem(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
    }

    func isTokenExpired() -> Bool {
        guard let expiry = UserDefaults.standard.object(forKey: tokenExpiryKey) as? Date else {
            return true
        }
        // Consider token expired 5 minutes before actual expiry
        return Date().addingTimeInterval(300) >= expiry
    }

    // MARK: - OAuth Flow with ASWebAuthenticationSession

    /// Start the OAuth flow using ASWebAuthenticationSession.
    ///
    /// Uses PKCE (RFC 7636). The client ID's redirect URI form
    /// (`com.googleusercontent.apps.<id>:/oauth2callback`) is the iOS-typed
    /// OAuth client format — Google now requires PKCE for these clients, and
    /// without it the issued refresh tokens come back as `invalid_grant` on
    /// first use. PKCE is harmless for web/desktop clients, so we always send it.
    @MainActor
    func startOAuthFlow() async throws -> (accessToken: String, refreshToken: String?) {
        guard hasClientId else { throw GoogleAuthError.missingClientId }

        let codeVerifier = Self.generatePKCEVerifier()
        let codeChallenge = Self.pkceChallenge(for: codeVerifier)

        guard let authURL = getAuthorizationURL(codeChallenge: codeChallenge) else {
            throw GoogleAuthError.invalidResponse
        }

        let scheme = callbackURLScheme

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: GoogleAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: GoogleAuthError.noAuthorizationCode)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = WebAuthContextProvider.shared
            // Use an ephemeral browser session so the auth flow doesn't reuse
            // Safari cookies — that path can silently re-issue tokens against
            // a degraded prior grant, or pick the wrong Google account when
            // the user is signed into several. Ephemeral makes the user pick
            // their account and consent every time, which is the right
            // behavior for a "Reconnect" flow.
            session.prefersEphemeralWebBrowserSession = true

            if !session.start() {
                continuation.resume(throwing: GoogleAuthError.sessionStartFailed)
            }
        }

        // Exchange the code for tokens, including the PKCE verifier so Google
        // can match it against the challenge it stashed during the auth step.
        return try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    /// Generate the authorization URL for the OAuth flow
    private func getAuthorizationURL(codeChallenge: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: requestedScopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    /// Re-run the full OAuth flow, requesting whatever the current scope set
    /// is. Used when the user toggles Drive on — the existing token covers
    /// Gmail/Calendar but doesn't include Drive scopes, so we need a fresh
    /// consent screen that lists the additional grants. Drops the old token
    /// first so the flow is a full reauthorisation (Google's consent screen
    /// re-shows even with `prompt=consent` set above, just to be sure).
    @MainActor
    func reauthorize() async throws -> (accessToken: String, refreshToken: String?) {
        signOut()
        return try await startOAuthFlow()
    }

    // MARK: - PKCE helpers

    /// Random ASCII string per RFC 7636 (43–128 chars from the unreserved set).
    /// We use 64 bytes of entropy → ~86 base64url chars, well within the limit.
    private static func generatePKCEVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Exchange authorization code for tokens
    func exchangeCodeForTokens(code: String, codeVerifier: String? = nil) async throws -> (accessToken: String, refreshToken: String?) {
        let url = URL(string: "https://oauth2.googleapis.com/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        var items = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        if let codeVerifier {
            items.append(URLQueryItem(name: "code_verifier", value: codeVerifier))
        }
        components.queryItems = items

        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDesc = errorJson["error_description"] as? String {
                throw GoogleAuthError.tokenExchangeFailed(errorDesc)
            }
            throw GoogleAuthError.tokenExchangeFailed("Status code: \(httpResponse.statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)

        // Store tokens
        setTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        return (tokenResponse.accessToken, tokenResponse.refreshToken)
    }

    /// Refresh the access token using the refresh token
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = getRefreshToken() else {
            throw GoogleAuthError.noRefreshToken
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]

        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Capture Google's actual reason — invalid_grant, invalid_scope,
            // unauthorized_client, etc. — so we can surface it in the UI
            // instead of a generic "needs reauth". Don't log the raw body to
            // the system console (it can contain a refresh_token in the
            // error envelope on some failure modes); just log the status.
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            NSLog("[Google refresh failed %d]", httpResponse.statusCode)
            // If refresh fails, user needs to re-authenticate
            signOut()
            throw GoogleAuthError.refreshFailedWithReason(status: httpResponse.statusCode, body: body)
        }

        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)

        // Update access token (refresh token may not be returned)
        setTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        return tokenResponse.accessToken
    }

    /// Get a valid access token, refreshing if necessary
    func getValidAccessToken() async throws -> String {
        if let token = getAccessToken(), !isTokenExpired() {
            return token
        }

        // Token is expired or missing, try to refresh
        return try await refreshAccessToken()
    }

    /// Send a Google API request with automatic Authorization header. If the
    /// server returns 401 (token revoked server-side, which our local expiry
    /// check can't see), force-refresh the access token once and retry. Throws
    /// `GoogleAuthError.refreshFailed` if the refresh token itself is dead and
    /// the user must reconnect.
    func performAuthorizedRequest(_ build: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var token = try await getValidAccessToken()
        var attempt = 0
        while true {
            var request = build()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleAuthError.invalidResponse
            }
            if http.statusCode == 401 {
                // Path of the failed request is useful diagnostics; the body
                // can carry user data (email addresses, etc.) so we omit it.
                let path = request.url?.path ?? "?"
                NSLog("[Google 401] path=%@ attempt=%d", path, attempt)
                if attempt == 0 {
                    do {
                        token = try await refreshAccessToken()
                    } catch {
                        NSLog("[Google 401] refresh failed after 401")
                        // Capture diagnostics about the dead access token to
                        // help debug from the UI: expiry, scopes, account.
                        await Self.logTokenDiagnostics()
                        throw error
                    }
                    attempt += 1
                    continue
                }
            }
            return (data, http)
        }
    }

    /// Hit Google's `tokeninfo` debug endpoint with the current access token
    /// and dump scopes/audience/expiry status to the console. Useful when
    /// refresh is failing — we only log the HTTP status code, not the body
    /// (which embeds scope strings and the user's Google account email).
    private static func logTokenDiagnostics() async {
        guard let token = GoogleAuthService.shared.getAccessToken() else {
            NSLog("[Google tokeninfo] no access token in keychain")
            return
        }
        // Pass the token in the Authorization header instead of the query
        // string. Query params land in URL request logs (URLSession, system
        // network logs, crash reports), where a still-valid access token is
        // a worse leak than a bearer header that stays in memory.
        guard let url = URL(string: "https://oauth2.googleapis.com/tokeninfo") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("[Google tokeninfo] http=%d", status)
        } catch {
            NSLog("[Google tokeninfo] error")
        }
    }

    // MARK: - Keychain Helpers

    private func setKeychainItem(key: String, value: String) {
        let data = value.data(using: .utf8)!

        // Delete any existing item for this (service, account) pair first.
        deleteKeychainItem(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // Surface failures — silent SecItemAdd failures were a major part
            // of the previous mystery. errSecDuplicateItem (-25299) shouldn't
            // happen because we deleted first, but log anything else too.
            NSLog("[Keychain] SecItemAdd failed for key=%@ status=%d", key, Int(status))
        }
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Web Auth Context Provider

class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        // OAuth presentation needs *some* window to anchor to. In practice
        // we always have a key window by the time OAuth fires (the user
        // tapped Connect inside a visible Settings sheet), but guard the
        // last-resort fallback so the app doesn't crash if both lookups
        // miss — synthesizing an off-screen window is harmless and
        // ASWebAuthenticationSession will just open in a standalone Safari.
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
        #endif
    }
}

// MARK: - Errors

enum GoogleAuthError: LocalizedError {
    case missingClientId
    case invalidResponse
    case tokenExchangeFailed(String)
    case noRefreshToken
    case refreshFailed
    case refreshFailedWithReason(status: Int, body: String)
    case noAuthorizationCode
    case userCancelled
    case sessionStartFailed

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Google OAuth Client ID is not set. Add one in Settings (Google Cloud Console → Credentials → OAuth client ID → Desktop app)."
        case .invalidResponse:
            return "Invalid response from Google"
        case .tokenExchangeFailed(let reason):
            return "Failed to exchange code for tokens: \(reason)"
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .refreshFailed:
            return "Failed to refresh access token. Please sign in again."
        case .refreshFailedWithReason(let status, let body):
            return "Token refresh failed (HTTP \(status)): \(body)"
        case .noAuthorizationCode:
            return "No authorization code received from Google"
        case .userCancelled:
            return "Sign in was cancelled"
        case .sessionStartFailed:
            return "Failed to start authentication session"
        }
    }
}
