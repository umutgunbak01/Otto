import Foundation

/// Per-tool approval state. Used by Hermes (ACP) to decide whether to ask
/// the user every time the agent wants to call a tool, or to honor a prior
/// "always allow" / "always deny" choice.
enum ApprovalDecision: String, Codable {
    case alwaysAllow
    case alwaysDeny
    case askEachTime
}

/// Persists the user's per-tool approval preferences. Tools the user hasn't
/// decided on default to `.askEachTime`.
///
/// Single global store — preferences aren't scoped per backend because the
/// tool surface (OttoTools) is identical no matter which agent is asking.
final class ToolApprovalPolicy: @unchecked Sendable {
    static let shared = ToolApprovalPolicy()

    private static let defaultsKeyPrefix = "hermes.approval."

    private let lock = NSLock()

    private init() {}

    func decision(for toolName: String) -> ApprovalDecision {
        lock.lock(); defer { lock.unlock() }
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKeyPrefix + toolName) ?? ""
        return ApprovalDecision(rawValue: raw) ?? .askEachTime
    }

    func setDecision(_ decision: ApprovalDecision, for toolName: String) {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.set(decision.rawValue, forKey: Self.defaultsKeyPrefix + toolName)
    }

    func reset(toolName: String) {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKeyPrefix + toolName)
    }
}
