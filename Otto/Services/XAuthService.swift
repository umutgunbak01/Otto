import Foundation
import AuthenticationServices
import Security
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - X Auth Service (OAuth 2.0 with PKCE)

final class XAuthService: @unchecked Sendable {
    static let shared = XAuthService()

    private let authBaseURL = "https://x.com/i/oauth2/authorize"
    private let tokenURL = "https://api.x.com/2/oauth2/token"
    private let redirectUri = "otto://x-callback"
    private let scopes = "tweet.read users.read dm.read bookmark.read follows.read offline.access"

    // Keychain keys
    private let accessTokenKey = "com.otto.x.accessToken"
    private let refreshTokenKey = "com.otto.x.refreshToken"
    private let tokenExpiryKey = "com.otto.x.tokenExpiry"
    private let xUserIdKey = "com.otto.x.userId"

    // PKCE state
    private var codeVerifier: String?

    private let lock = NSLock()

    private init() {}

    // MARK: - Client ID (user-configured)

    var clientId: String {
        get { UserDefaults.standard.string(forKey: "x_client_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "x_client_id") }
    }

    var hasClientId: Bool {
        !clientId.isEmpty
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

    func getUserId() -> String? {
        UserDefaults.standard.string(forKey: xUserIdKey)
    }

    func setUserId(_ userId: String) {
        UserDefaults.standard.set(userId, forKey: xUserIdKey)
    }

    func setTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
        lock.lock()
        defer { lock.unlock() }

        setKeychainItem(key: accessTokenKey, value: accessToken)
        if let refreshToken = refreshToken {
            setKeychainItem(key: refreshTokenKey, value: refreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        UserDefaults.standard.set(expiry, forKey: tokenExpiryKey)
    }

    func signOut() {
        lock.lock()
        defer { lock.unlock() }

        deleteKeychainItem(key: accessTokenKey)
        deleteKeychainItem(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        UserDefaults.standard.removeObject(forKey: xUserIdKey)
    }

    func isTokenExpired() -> Bool {
        guard let expiry = UserDefaults.standard.object(forKey: tokenExpiryKey) as? Date else {
            return true
        }
        return Date().addingTimeInterval(300) >= expiry
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - OAuth Flow

    @MainActor
    func startOAuthFlow() async throws -> (accessToken: String, refreshToken: String?) {
        guard hasClientId else {
            throw XAuthError.noClientId
        }

        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: authBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            throw XAuthError.invalidURL
        }

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "otto"
            ) { callbackURL, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: XAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: XAuthError.noAuthorizationCode)
                    return
                }

                // Verify state
                let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                guard returnedState == state else {
                    continuation.resume(throwing: XAuthError.stateMismatch)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = WebAuthContextProvider.shared
            session.prefersEphemeralWebBrowserSession = false

            if !session.start() {
                continuation.resume(throwing: XAuthError.sessionStartFailed)
            }
        }

        return try await exchangeCodeForTokens(code: code)
    }

    /// Handle the OAuth callback URL (called from OttoApp's onOpenURL)
    func handleCallback(url: URL) async throws -> (accessToken: String, refreshToken: String?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw XAuthError.noAuthorizationCode
        }

        return try await exchangeCodeForTokens(code: code)
    }

    /// Exchange authorization code for tokens
    private func exchangeCodeForTokens(code: String) async throws -> (accessToken: String, refreshToken: String?) {
        guard let verifier = codeVerifier else {
            throw XAuthError.noPKCEVerifier
        }

        let url = URL(string: tokenURL)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]

        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDesc = errorJson["error_description"] as? String {
                throw XAuthError.tokenExchangeFailed(errorDesc)
            }
            throw XAuthError.tokenExchangeFailed("Status code: \(httpResponse.statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(XTokenResponse.self, from: data)

        setTokens(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: tokenResponse.expiresIn
        )

        codeVerifier = nil

        return (tokenResponse.accessToken, tokenResponse.refreshToken)
    }

    /// Refresh the access token
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = getRefreshToken() else {
            throw XAuthError.noRefreshToken
        }

        let url = URL(string: tokenURL)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientId)
        ]

        request.httpBody = bodyComponents.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            signOut()
            throw XAuthError.refreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(XTokenResponse.self, from: data)

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
        return try await refreshAccessToken()
    }

    // MARK: - Keychain Helpers

    private func setKeychainItem(key: String, value: String) {
        let data = value.data(using: .utf8)!
        deleteKeychainItem(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
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
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum XAuthError: LocalizedError {
    case noClientId
    case invalidURL
    case invalidResponse
    case tokenExchangeFailed(String)
    case noRefreshToken
    case refreshFailed
    case noAuthorizationCode
    case userCancelled
    case sessionStartFailed
    case stateMismatch
    case noPKCEVerifier

    var errorDescription: String? {
        switch self {
        case .noClientId:
            return "No X Client ID configured. Add your Client ID in Integrations."
        case .invalidURL:
            return "Invalid authorization URL"
        case .invalidResponse:
            return "Invalid response from X API"
        case .tokenExchangeFailed(let reason):
            return "Failed to exchange code for tokens: \(reason)"
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .refreshFailed:
            return "Failed to refresh access token. Please sign in again."
        case .noAuthorizationCode:
            return "No authorization code received from X"
        case .userCancelled:
            return "Sign in was cancelled"
        case .sessionStartFailed:
            return "Failed to start authentication session"
        case .stateMismatch:
            return "OAuth state mismatch. Please try again."
        case .noPKCEVerifier:
            return "Missing PKCE code verifier. Please restart the sign in flow."
        }
    }
}
