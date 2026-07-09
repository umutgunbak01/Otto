import Foundation
import AuthenticationServices
import Security
import CryptoKit

/// OAuth engine for custom MCP servers, per the MCP authorization spec.
///
/// Sign-in (`authorize`) runs the full chain interactively:
///   1. Discovery — RFC 9728 protected-resource metadata on the MCP server
///      → RFC 8414 / OIDC metadata on the authorization server it names.
///      Falls back to the MCP origin's own metadata, then to the spec's
///      default endpoints (`/authorize`, `/token`, `/register`), so
///      pre-metadata servers still work.
///   2. Client — the user-supplied Client ID (+ optional secret) when set,
///      otherwise RFC 7591 dynamic registration as a public client.
///   3. Grant — authorization-code + PKCE via `ASWebAuthenticationSession`
///      (same pattern as `GoogleAuthService`), with an RFC 8707 `resource`
///      indicator naming the MCP server.
///   4. Persist — tokens land in Keychain via
///      `CustomMCPServersStore.setOAuthState`.
///
/// Turn time (`validAccessToken`) is non-interactive: cached token while
/// fresh, refresh-token grant when near expiry, throw when only a new
/// browser sign-in can help — callers skip the server for that turn and the
/// UI shows "Sign in".
final class CustomMCPOAuthService: @unchecked Sendable {
    static let shared = CustomMCPOAuthService()

    /// Custom-scheme callback, sibling of XAuthService's `otto://x-callback`.
    /// ASWebAuthenticationSession intercepts the scheme inside the session,
    /// so no extra Info.plist registration is needed.
    private static let redirectUri = "otto://mcp-oauth-callback"
    private static let callbackScheme = "otto"

    /// Refresh when within 5 minutes of expiry — same buffer as Google.
    private static let expiryBuffer: TimeInterval = 300

    private init() {}

    enum OAuthError: LocalizedError {
        case remoteOnly
        case invalidServerURL
        case discoveryFailed(String)
        case registrationRequired
        case registrationFailed(String)
        case userCancelled
        case sessionStartFailed
        case badCallback
        case tokenExchangeFailed(String)
        case notConnected
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .remoteOnly:
                return "OAuth sign-in only applies to remote (URL) servers."
            case .invalidServerURL:
                return "The server URL is not a valid URL."
            case .discoveryFailed(let m):
                return "OAuth discovery failed: \(m)"
            case .registrationRequired:
                return "This server doesn't support automatic client registration. Enter an OAuth Client ID."
            case .registrationFailed(let m):
                return "Client registration failed: \(m)"
            case .userCancelled:
                return "Sign-in was cancelled."
            case .sessionStartFailed:
                return "Couldn't open the sign-in window."
            case .badCallback:
                return "The sign-in redirect was missing the authorization code."
            case .tokenExchangeFailed(let m):
                return "Token exchange failed: \(m)"
            case .notConnected:
                return "Not signed in yet."
            case .refreshFailed(let m):
                return "Token refresh failed: \(m)"
            }
        }
    }

    /// Row-level status for the Integrations UI.
    enum ConnectionStatus {
        case connected
        case needsSignIn
    }

    func status(for server: CustomMCPServer) -> ConnectionStatus {
        return CustomMCPServersStore.shared.oauthState(for: server.id) != nil
            ? .connected : .needsSignIn
    }

    func disconnect(serverId: UUID) {
        CustomMCPServersStore.shared.clearOAuthState(for: serverId)
    }

    // MARK: - Interactive sign-in

    /// Full browser sign-in. MainActor because ASWebAuthenticationSession
    /// must present from the UI; the network legs are plain awaits.
    @MainActor
    func authorize(server: CustomMCPServer) async throws {
        guard server.transport != .stdio else { throw OAuthError.remoteOnly }
        guard let mcpURL = URL(string: server.url), mcpURL.host != nil else {
            throw OAuthError.invalidServerURL
        }

        let discovery = try await Self.discover(mcpURL: mcpURL)

        // Client credentials: user-supplied beats dynamic registration.
        let clientId: String
        var clientSecret: String? = nil
        if let userClientId = server.oauthClientId, !userClientId.isEmpty {
            clientId = userClientId
            let stored = CustomMCPServersStore.shared.secrets(for: server.id).oauthClientSecret
            clientSecret = (stored?.isEmpty == false) ? stored : nil
        } else if let registrationEndpoint = discovery.registrationEndpoint {
            let registered = try await Self.registerClient(endpoint: registrationEndpoint)
            clientId = registered.clientId
            clientSecret = registered.clientSecret
        } else {
            throw OAuthError.registrationRequired
        }

        // Authorization-code grant with PKCE + state.
        let codeVerifier = Self.generatePKCEVerifier()
        let state = Self.generatePKCEVerifier()
        guard var components = URLComponents(url: discovery.authorizationEndpoint,
                                             resolvingAgainstBaseURL: false) else {
            throw OAuthError.discoveryFailed("Bad authorization endpoint.")
        }
        var query: [URLQueryItem] = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectUri),
            URLQueryItem(name: "code_challenge", value: Self.pkceChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: discovery.resource)
        ]
        if let scope = discovery.scope {
            query.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = query
        guard let authURL = components.url else {
            throw OAuthError.discoveryFailed("Couldn't build the authorization URL.")
        }

        let code = try await Self.runBrowserSession(authURL: authURL, expectedState: state)

        // Exchange the code, persist the grant.
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectUri,
            "client_id": clientId,
            "code_verifier": codeVerifier,
            "resource": discovery.resource
        ]
        if let clientSecret {
            form["client_secret"] = clientSecret
        }
        let token = try await Self.tokenRequest(endpoint: discovery.tokenEndpoint, form: form)

        CustomMCPServersStore.shared.setOAuthState(CustomMCPOAuthState(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenEndpoint: discovery.tokenEndpoint.absoluteString,
            clientId: clientId,
            clientSecret: clientSecret,
            resource: discovery.resource
        ), for: server.id)
    }

    // MARK: - Turn-time token access

    /// Cached token while fresh; refresh-token grant when near expiry.
    /// Throws when interactive sign-in is required. A rejected refresh
    /// (`invalid_grant`) clears the stored state so the UI flips to
    /// "Sign in" instead of retrying a dead grant every turn.
    func validAccessToken(for server: CustomMCPServer) async throws -> String {
        guard let state = CustomMCPServersStore.shared.oauthState(for: server.id) else {
            throw OAuthError.notConnected
        }
        let nearExpiry: Bool
        if let expiresAt = state.expiresAt {
            nearExpiry = Date().addingTimeInterval(Self.expiryBuffer) >= expiresAt
        } else {
            nearExpiry = false // no expiry reported — use until the server 401s
        }
        guard nearExpiry else { return state.accessToken }
        guard let refreshToken = state.refreshToken, !refreshToken.isEmpty,
              let endpoint = URL(string: state.tokenEndpoint) else {
            throw OAuthError.notConnected
        }

        var form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": state.clientId
        ]
        if let secret = state.clientSecret { form["client_secret"] = secret }
        if let resource = state.resource { form["resource"] = resource }

        do {
            let token = try await Self.tokenRequest(endpoint: endpoint, form: form)
            var updated = state
            updated.accessToken = token.accessToken
            // Refresh-token rotation: keep the old one unless a new one came back.
            if let rotated = token.refreshToken, !rotated.isEmpty {
                updated.refreshToken = rotated
            }
            updated.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            CustomMCPServersStore.shared.setOAuthState(updated, for: server.id)
            return token.accessToken
        } catch let error as OAuthError {
            if case .tokenExchangeFailed(let message) = error, message.contains("invalid_grant") {
                CustomMCPServersStore.shared.clearOAuthState(for: server.id)
            }
            throw OAuthError.refreshFailed(error.localizedDescription)
        }
    }

    // MARK: - Auth auto-detection

    /// Connect-time probe for the add-server flow: does this URL demand
    /// OAuth? Sends an MCP `initialize` POST — a 401 is the spec's signal
    /// for bearer auth (RFC 9728). When that request is inconclusive (legacy
    /// SSE servers 405 a bare POST, network hiccups, …), advertised
    /// protected-resource metadata decides. Defaults to no-auth so keyless
    /// servers connect without ceremony.
    static func requiresOAuth(mcpURL: URL) async -> Bool {
        var request = URLRequest(url: mcpURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Otto", "version": "1.0"]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: initialize)
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { return true }
            if (200...299).contains(http.statusCode) { return false }
        }
        guard let origin = Self.origin(of: mcpURL) else { return false }
        for metaURL in wellKnownCandidates(origin: origin, path: mcpURL.path,
                                           suffix: "oauth-protected-resource") {
            if let json = await fetchJSON(metaURL),
               json["authorization_servers"] != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Discovery

    struct Discovery {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scope: String?     // space-joined scopes_supported, when advertised
        var resource: String   // RFC 8707 resource indicator = the MCP URL
    }

    static func discover(mcpURL: URL) async throws -> Discovery {
        let resource = mcpURL.absoluteString
        guard let origin = Self.origin(of: mcpURL) else {
            throw OAuthError.invalidServerURL
        }

        // 1) RFC 9728 protected-resource metadata: path-aware first
        //    (/.well-known/oauth-protected-resource/<path>), then root.
        var authServerBase: URL? = nil
        var scope: String? = nil
        for metaURL in wellKnownCandidates(origin: origin, path: mcpURL.path,
                                           suffix: "oauth-protected-resource") {
            guard let json = await fetchJSON(metaURL) else { continue }
            if let servers = json["authorization_servers"] as? [String],
               let first = servers.first, let url = URL(string: first) {
                authServerBase = url
            }
            if let scopes = json["scopes_supported"] as? [String], !scopes.isEmpty {
                scope = scopes.joined(separator: " ")
            }
            if authServerBase != nil { break }
        }
        // Pre-metadata servers: the MCP origin doubles as the auth server.
        let issuer = authServerBase ?? origin

        // 2) RFC 8414 auth-server metadata (then OIDC discovery) on the issuer.
        guard let issuerOrigin = Self.origin(of: issuer) else {
            throw OAuthError.discoveryFailed("Bad authorization server URL.")
        }
        var authMeta: [String: Any]? = nil
        for metaURL in wellKnownCandidates(origin: issuerOrigin, path: issuer.path,
                                           suffix: "oauth-authorization-server")
            + wellKnownCandidates(origin: issuerOrigin, path: issuer.path,
                                  suffix: "openid-configuration") {
            if let json = await fetchJSON(metaURL),
               json["authorization_endpoint"] is String,
               json["token_endpoint"] is String {
                authMeta = json
                break
            }
        }

        if let meta = authMeta,
           let authStr = meta["authorization_endpoint"] as? String,
           let tokenStr = meta["token_endpoint"] as? String,
           let authEndpoint = URL(string: authStr),
           let tokenEndpoint = URL(string: tokenStr) {
            let registration = (meta["registration_endpoint"] as? String).flatMap(URL.init(string:))
            return Discovery(
                authorizationEndpoint: authEndpoint,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: registration,
                scope: scope,
                resource: resource
            )
        }

        // 3) Spec-default endpoints on the issuer origin (2025-03-26
        //    backwards-compat section).
        return Discovery(
            authorizationEndpoint: issuerOrigin.appendingPathComponent("authorize"),
            tokenEndpoint: issuerOrigin.appendingPathComponent("token"),
            registrationEndpoint: issuerOrigin.appendingPathComponent("register"),
            scope: scope,
            resource: resource
        )
    }

    /// Path-aware well-known URL first (RFC 9728 / RFC 8414 style), then the
    /// root form; duplicates removed when the resource has no path.
    static func wellKnownCandidates(origin: URL, path: String, suffix: String) -> [URL] {
        var out: [URL] = []
        let trimmedPath = path == "/" ? "" : path
        if !trimmedPath.isEmpty {
            out.append(origin.appendingPathComponent(".well-known/\(suffix)\(trimmedPath)"))
        }
        out.append(origin.appendingPathComponent(".well-known/\(suffix)"))
        return out
    }

    static func origin(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var s = "\(scheme)://\(host)"
        if let port = url.port { s += ":\(port)" }
        return URL(string: s)
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Dynamic client registration (RFC 7591)

    private static func registerClient(endpoint: URL) async throws -> (clientId: String, clientSecret: String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": "Otto",
            "redirect_uris": [redirectUri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            // Public client — native app, no secret to keep.
            "token_endpoint_auth_method": "none"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthError.registrationFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String, !clientId.isEmpty else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw OAuthError.registrationFailed(String(detail))
        }
        return (clientId, json["client_secret"] as? String)
    }

    // MARK: - Browser session

    @MainActor
    private static func runBrowserSession(authURL: URL, expectedState: String) async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
                else {
                    continuation.resume(throwing: OAuthError.badCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = WebAuthContextProvider.shared
            if !session.start() {
                continuation.resume(throwing: OAuthError.sessionStartFailed)
            }
        }
    }

    // MARK: - Token endpoint

    private struct TokenResult {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int?
    }

    private static func tokenRequest(endpoint: URL, form: [String: String]) async throws -> TokenResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Strict per-field encoding — URLComponents leaves `+` bare in query
        // strings, and form parsers decode bare `+` as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthError.tokenExchangeFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("No HTTP response.")
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            // Surface the OAuth error code (e.g. invalid_grant) — refresh
            // handling keys off it.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["error"] as? String {
                let desc = json["error_description"] as? String ?? ""
                throw OAuthError.tokenExchangeFailed("\(code) \(desc)".trimmingCharacters(in: .whitespaces))
            }
            throw OAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }
        return TokenResult(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: json["expires_in"] as? Int
        )
    }

    // MARK: - PKCE helpers (same construction as GoogleAuthService)

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
}
