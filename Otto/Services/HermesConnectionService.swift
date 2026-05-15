import Foundation

/// The user's pre-provisioned Hetzner box that runs `hermes acp`. Otto is a
/// pure client — we never generate keys, install Hermes, or write its config.
/// All the user gives us is enough to open an SSH connection.
struct HermesConnection: Codable, Equatable {
    var host: String
    var username: String
    var port: Int
    var privateKeyPath: String

    static let defaultPort = 22

    /// Trims and validates fields. Throws on empty host/user/key, returns a
    /// connection with `port` defaulted to 22 when given <= 0.
    static func make(host: String, username: String, port: Int, privateKeyPath: String) throws -> HermesConnection {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { throw HermesConnectionError.emptyHost }
        guard !u.isEmpty else { throw HermesConnectionError.emptyUsername }
        guard !k.isEmpty else { throw HermesConnectionError.emptyKeyPath }
        let p = (port > 0 && port <= 65535) ? port : defaultPort
        return HermesConnection(host: h, username: u, port: p, privateKeyPath: k)
    }

    /// Expand `~` and `$HOME` so the path can be handed directly to `ssh -i`.
    func resolvedKeyPath() -> String {
        return (privateKeyPath as NSString).expandingTildeInPath
    }
}

enum HermesConnectionError: LocalizedError {
    case emptyHost
    case emptyUsername
    case emptyKeyPath

    var errorDescription: String? {
        switch self {
        case .emptyHost:     return "Host is required."
        case .emptyUsername: return "SSH username is required."
        case .emptyKeyPath:  return "Path to your SSH private key is required."
        }
    }
}

/// Single-connection store. v1 supports one Hetzner box per user — schema is
/// a single Codable blob under one UserDefaults key, no Keychain (the SSH key
/// is a file path, not a credential string).
final class HermesConnectionService: @unchecked Sendable {
    static let shared = HermesConnectionService()

    private static let defaultsKey = "hermes.connection"

    private let lock = NSLock()

    private init() {}

    func current() -> HermesConnection? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(HermesConnection.self, from: raw)
        else { return nil }
        return decoded
    }

    func save(_ connection: HermesConnection) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(connection) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
