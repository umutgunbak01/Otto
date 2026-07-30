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

    /// Conversation keys whose in-flight run auto-approves EVERY tool
    /// permission request — scheduled-task runs whose per-task
    /// "auto-approve" toggle is on. In-memory only: the scheduler registers
    /// the run's session key for the duration of the run, so an unattended
    /// run can never stall on an approval card. If the user later reopens
    /// that chat session and keeps talking, approvals behave normally again
    /// (the registration ended with the run).
    private var autoApproveSessions: Set<UUID> = []

    private init() {}

    func beginAutoApprovingSession(_ key: UUID) {
        lock.lock(); defer { lock.unlock() }
        autoApproveSessions.insert(key)
    }

    func endAutoApprovingSession(_ key: UUID) {
        lock.lock(); defer { lock.unlock() }
        autoApproveSessions.remove(key)
    }

    func isAutoApproving(session key: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return autoApproveSessions.contains(key)
    }

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
