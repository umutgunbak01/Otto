import Foundation
import Security

/// Secret half of a custom MCP server config — env values for stdio
/// commands, header values for remote servers, and the optional OAuth client
/// secret for pre-registered clients. Stored as one Keychain JSON blob per
/// server so tokens never sit in UserDefaults.
struct CustomMCPServerSecrets: Codable, Equatable {
    var env: [String: String] = [:]
    var headers: [String: String] = [:]
    var oauthClientSecret: String? = nil

    var isEmpty: Bool { env.isEmpty && headers.isEmpty && (oauthClientSecret ?? "").isEmpty }
}

/// Live OAuth grant for a custom MCP server — written by
/// `CustomMCPOAuthService` after sign-in, read/updated on every refresh.
/// Persisted as its own Keychain item (`<server-uuid>.oauth`) so token
/// rotation never races the user-edited config secrets.
struct CustomMCPOAuthState: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientId: String
    var clientSecret: String?
    /// RFC 8707 resource indicator (the MCP server URL) — replayed on
    /// refresh so the auth server scopes the new token correctly.
    var resource: String?
}

enum CustomMCPServersError: LocalizedError {
    case emptyName
    case reservedName(String)
    case emptyCommand
    case invalidURL
    case invalidJSON
    case noServersInJSON
    case oauthNeedsRemote

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Name is required."
        case .reservedName(let slug):
            return "\"\(slug)\" collides with a built-in Otto server name. Pick a different name."
        case .emptyCommand:
            return "Command is required for a stdio server."
        case .invalidURL:
            return "URL must start with https:// (or http:// for localhost)."
        case .invalidJSON:
            return "Couldn't parse that as JSON. Paste the standard {\"mcpServers\": {…}} config snippet."
        case .noServersInJSON:
            return "No MCP servers found in that JSON. Expected {\"mcpServers\": {\"name\": {\"command\"|\"url\": …}}}."
        case .oauthNeedsRemote:
            return "OAuth sign-in only applies to remote (URL) servers."
        }
    }
}

/// Storage + config generation for user-added MCP servers. Mirrors
/// `SupabaseProjectsService`: non-secret fields as a JSON blob in
/// UserDefaults, secrets in Keychain (service `com.otto.custommcp`, account =
/// server UUID, `WhenUnlockedThisDeviceOnly`), a single `NSLock` guarding
/// every path so add/delete/toggle can't interleave.
///
/// The three agent backends each pull `enabledServers()` at launch/session
/// time and translate them via the `claudeEntry` / `codexArgs` / `acpEntry`
/// generators below — Otto itself never speaks MCP to these servers.
final class CustomMCPServersStore: @unchecked Sendable {
    static let shared = CustomMCPServersStore()

    private static let keychainService = "com.otto.custommcp"
    private static let defaultsKey = "custommcp.servers"

    private let lock = NSLock()

    private init() {}

    // MARK: - Read

    /// All servers sorted by createdAt ascending — stable order for the
    /// Integrations list and the injected config.
    func allServers() -> [CustomMCPServer] {
        withLock { unlockedAllServers() }
    }

    func enabledServers() -> [CustomMCPServer] {
        withLock { unlockedAllServers().filter(\.enabled) }
    }

    /// Missing Keychain item (e.g. after a profile migration) degrades to
    /// empty secrets — the server is still injected, just unauthenticated.
    func secrets(for id: UUID) -> CustomMCPServerSecrets {
        withLock {
            guard let raw = getKeychainItem(account: id.uuidString),
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CustomMCPServerSecrets.self, from: data)
            else { return CustomMCPServerSecrets() }
            return decoded
        }
    }

    /// Config secrets with a fresh OAuth Bearer merged in for `.oauth`
    /// servers. Returns nil when no valid token can be produced (never
    /// signed in, refresh rejected) — callers skip the server for this turn,
    /// mirroring how the Google servers degrade when their token fetch fails.
    func effectiveSecrets(for server: CustomMCPServer) async -> CustomMCPServerSecrets? {
        var secrets = secrets(for: server.id)
        guard server.usesOAuth else { return secrets }
        do {
            let token = try await CustomMCPOAuthService.shared.validAccessToken(for: server)
            secrets.headers["Authorization"] = "Bearer \(token)"
            return secrets
        } catch {
            NSLog("[CustomMCP] %@ skipped — OAuth token unavailable: %@",
                  server.slug, error.localizedDescription)
            return nil
        }
    }

    // MARK: - OAuth state (used by CustomMCPOAuthService)

    func oauthState(for id: UUID) -> CustomMCPOAuthState? {
        withLock {
            guard let raw = getKeychainItem(account: id.uuidString + ".oauth"),
                  let data = raw.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(CustomMCPOAuthState.self, from: data)
        }
    }

    func setOAuthState(_ state: CustomMCPOAuthState, for id: UUID) {
        withLock {
            guard let data = try? JSONEncoder().encode(state),
                  let value = String(data: data, encoding: .utf8) else { return }
            setKeychainItem(account: id.uuidString + ".oauth", value: value)
        }
    }

    func clearOAuthState(for id: UUID) {
        withLock { deleteKeychainItem(account: id.uuidString + ".oauth") }
    }

    // MARK: - Write

    /// Validates, derives a unique non-reserved slug, stores secrets in
    /// Keychain, and appends to the list. Throws `CustomMCPServersError` on
    /// bad input.
    @discardableResult
    func addServer(
        name: String,
        transport: CustomMCPTransport,
        command: String = "",
        args: [String] = [],
        url: String = "",
        secrets: CustomMCPServerSecrets = CustomMCPServerSecrets(),
        enabled: Bool = true,
        auth: CustomMCPAuth = .headers,
        oauthClientId: String = ""
    ) throws -> CustomMCPServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientId = oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { throw CustomMCPServersError.emptyName }
        switch transport {
        case .stdio:
            guard !trimmedCommand.isEmpty else { throw CustomMCPServersError.emptyCommand }
            guard auth == .headers else { throw CustomMCPServersError.oauthNeedsRemote }
        case .http, .sse:
            guard Self.isAcceptableURL(trimmedURL) else { throw CustomMCPServersError.invalidURL }
        }

        let id = UUID()

        return try withLock {
            var slug = CustomMCPServer.slugify(trimmedName, fallbackId: id)
            if CustomMCPServer.isReservedSlug(slug) {
                // `github` → `github_mcp` before falling back to `_2` suffixes,
                // so reserved collisions get a readable name.
                let candidate = slug + "_mcp"
                slug = CustomMCPServer.isReservedSlug(candidate) ? "custom_" + slug : candidate
            }
            slug = uniqueSlug(base: slug, existing: unlockedAllServers().map(\.slug))
            guard !CustomMCPServer.isReservedSlug(slug) else {
                throw CustomMCPServersError.reservedName(slug)
            }

            let server = CustomMCPServer(
                id: id,
                name: trimmedName,
                slug: slug,
                transport: transport,
                enabled: enabled,
                createdAt: Date(),
                command: trimmedCommand,
                args: args.filter { !$0.isEmpty },
                url: trimmedURL,
                auth: auth == .headers ? nil : auth,
                oauthClientId: trimmedClientId.isEmpty ? nil : trimmedClientId
            )

            if !secrets.isEmpty {
                setSecrets(secrets, account: id.uuidString)
            }
            var list = unlockedAllServers()
            list.append(server)
            unlockedWriteAll(list)
            return server
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        withLock {
            var list = unlockedAllServers()
            guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
            list[idx].enabled = enabled
            unlockedWriteAll(list)
        }
    }

    func deleteServer(_ id: UUID) {
        withLock {
            deleteKeychainItem(account: id.uuidString)
            deleteKeychainItem(account: id.uuidString + ".oauth")
            let remaining = unlockedAllServers().filter { $0.id != id }
            unlockedWriteAll(remaining)
        }
    }

    // MARK: - JSON import

    /// Parses the de-facto standard MCP config snippet that every server's
    /// README publishes for Claude Desktop / Claude Code:
    ///
    ///     { "mcpServers": { "github": { "command": "npx", "args": […], "env": {…} },
    ///                       "linear": { "type": "http", "url": "…", "headers": {…} } } }
    ///
    /// Also accepts the inner dict without the `mcpServers` wrapper. Entries
    /// with `command` become stdio; entries with `url` become http (or sse
    /// when `type` says so). Adds every parsed server; returns them. Throws
    /// on malformed JSON, an empty server dict, or a per-server validation
    /// failure (nothing is added in that case — parse first, commit after).
    @discardableResult
    func importServers(fromJSON raw: String) throws -> [CustomMCPServer] {
        guard let data = raw.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CustomMCPServersError.invalidJSON }

        let dict = (top["mcpServers"] as? [String: Any]) ?? top
        var drafts: [(name: String, transport: CustomMCPTransport, command: String,
                      args: [String], url: String, secrets: CustomMCPServerSecrets)] = []

        for (name, value) in dict.sorted(by: { $0.key < $1.key }) {
            guard let cfg = value as? [String: Any] else { continue }
            if let command = cfg["command"] as? String, !command.isEmpty {
                var secrets = CustomMCPServerSecrets()
                secrets.env = (cfg["env"] as? [String: String]) ?? [:]
                drafts.append((
                    name: name, transport: .stdio, command: command,
                    args: (cfg["args"] as? [String]) ?? [], url: "", secrets: secrets
                ))
            } else if let url = cfg["url"] as? String, !url.isEmpty {
                let type = (cfg["type"] as? String ?? "").lowercased()
                let transport: CustomMCPTransport = type == "sse" ? .sse : .http
                var secrets = CustomMCPServerSecrets()
                secrets.headers = (cfg["headers"] as? [String: String]) ?? [:]
                drafts.append((
                    name: name, transport: transport, command: "",
                    args: [], url: url, secrets: secrets
                ))
            }
        }

        guard !drafts.isEmpty else { throw CustomMCPServersError.noServersInJSON }

        // Validate everything before committing anything, so a bad entry in
        // a multi-server paste doesn't leave a half-imported list.
        for draft in drafts {
            if draft.transport != .stdio, !Self.isAcceptableURL(draft.url) {
                throw CustomMCPServersError.invalidURL
            }
        }

        var added: [CustomMCPServer] = []
        for draft in drafts {
            added.append(try addServer(
                name: draft.name,
                transport: draft.transport,
                command: draft.command,
                args: draft.args,
                url: draft.url,
                secrets: draft.secrets
            ))
        }
        return added
    }

    /// https anywhere; plain http only for loopback (local dev servers).
    static func isAcceptableURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return false
    }

    // MARK: - Backend config generation

    /// Claude CLI `--mcp-config` entry (JSON, one per server key).
    static func claudeEntry(for server: CustomMCPServer, secrets: CustomMCPServerSecrets) -> [String: Any] {
        switch server.transport {
        case .stdio:
            return [
                "command": server.command,
                "args": server.args,
                "env": secrets.env
            ]
        case .http, .sse:
            return [
                "type": server.transport == .sse ? "sse" : "http",
                "url": server.url,
                "headers": secrets.headers
            ]
        }
    }

    /// Codex `-c key=tomlvalue` overrides. Returns [] for transports Codex
    /// can't drive (sse) — caller logs and skips. Bearer-style auth headers
    /// ride in env vars (Codex's `bearer_token_env_var` indirection, same as
    /// the built-in Tally/Supabase servers) so tokens stay out of `ps` output;
    /// other header values and stdio env values have no file/env channel in
    /// `codex exec`, so they are passed inline as TOML and are visible in the
    /// process table for the life of the turn.
    static func codexArgs(
        for server: CustomMCPServer,
        secrets: CustomMCPServerSecrets,
        env: inout [String: String]
    ) -> [String] {
        let key = "mcp_servers.\(server.slug)"
        switch server.transport {
        case .sse:
            return []
        case .stdio:
            var args: [String] = [
                "-c", "\(key).command=\(tomlString(server.command))",
                "-c", "\(key).args=[\(server.args.map(tomlString).joined(separator: ","))]"
            ]
            for (name, value) in secrets.env.sorted(by: { $0.key < $1.key }) {
                args.append(contentsOf: ["-c", "\(key).env.\(name)=\(tomlString(value))"])
            }
            return args
        case .http:
            var args: [String] = [
                "-c", "\(key).url=\(tomlString(server.url))",
                "-c", "\(key).transport=\"streamable_http\""
            ]
            for (name, value) in secrets.headers.sorted(by: { $0.key < $1.key }) {
                if name.lowercased() == "authorization", value.hasPrefix("Bearer ") {
                    let envVarName = "OTTO_CUSTOM_MCP_\(server.slug.uppercased())_BEARER_TOKEN"
                    args.append(contentsOf: ["-c", "\(key).bearer_token_env_var=\(tomlString(envVarName))"])
                    env[envVarName] = String(value.dropFirst("Bearer ".count))
                } else {
                    args.append(contentsOf: ["-c", "\(key).http_headers.\(tomlBareKey(name))=\(tomlString(value))"])
                }
            }
            return args
        }
    }

    /// ACP `session/new` `mcpServers` entry (Hermes). HTTP/SSE carry a `type`
    /// discriminator; stdio is ACP's untagged default variant, with env as
    /// `[{name, value}]` pairs (see `ACPParser.newSessionRequest` doc).
    static func acpEntry(for server: CustomMCPServer, secrets: CustomMCPServerSecrets) -> [String: Any] {
        switch server.transport {
        case .stdio:
            return [
                "name": server.slug,
                "command": server.command,
                "args": server.args,
                "env": secrets.env
                    .sorted { $0.key < $1.key }
                    .map { ["name": $0.key, "value": $0.value] as [String: Any] }
            ]
        case .http, .sse:
            return [
                "type": server.transport == .sse ? "sse" : "http",
                "name": server.slug,
                "url": server.url,
                "headers": secrets.headers
                    .sorted { $0.key < $1.key }
                    .map { ["name": $0.key, "value": $0.value] as [String: Any] }
            ]
        }
    }

    /// TOML basic-string literal: escape backslash and double-quote, wrap in
    /// quotes. Control characters are stripped — none survive the UI's
    /// single-line inputs anyway.
    private static func tomlString(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if ch.value >= 0x20 { out.unicodeScalars.append(ch) }
            }
        }
        return "\"\(out)\""
    }

    /// Header names appear as TOML keys — quote them so `-` and other
    /// non-bare characters parse.
    private static func tomlBareKey(_ s: String) -> String {
        return tomlString(s)
    }

    // MARK: - Lock helpers

    private func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }

    private func unlockedAllServers() -> [CustomMCPServer] {
        guard let raw = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomMCPServer].self, from: raw)
        else { return [] }
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func unlockedWriteAll(_ list: [CustomMCPServer]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func uniqueSlug(base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    // MARK: - Keychain (mirrors SupabaseProjectsService) — caller holds the lock

    private func setSecrets(_ secrets: CustomMCPServerSecrets, account: String) {
        guard let data = try? JSONEncoder().encode(secrets),
              let value = String(data: data, encoding: .utf8) else { return }
        setKeychainItem(account: account, value: value)
    }

    private func setKeychainItem(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteKeychainItem(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // No iCloud sync, no other macOS users on this device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[CustomMCP] SecItemAdd failed status=%d", Int(status))
        }
    }

    private func getKeychainItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
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

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
