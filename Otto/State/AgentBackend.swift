import Foundation

/// Which AI backend powers the Otto agent. Both backends drive a CLI
/// subprocess that we wire to Otto's MCP server — same tool-execution path,
/// different binary / auth source / model space.
enum AgentBackend: String, CaseIterable, Identifiable {
    case claude
    case codex
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .hermes: return "Hermes"
        }
    }

    static let defaultsKey = "agent.backend"

    /// Read from UserDefaults on every call so a Settings change takes effect
    /// without restarting the app (mirrors how the model id works).
    static var current: AgentBackend {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return AgentBackend(rawValue: raw) ?? .claude
    }

    static func set(_ backend: AgentBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: defaultsKey)
    }
}
