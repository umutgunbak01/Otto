import Foundation

/// Shared plumbing for background one-shot LLM runs (person dossiers, reply
/// drafts): pick the user's selected backend if it's usable, run a single
/// prompt through it with no UI streaming, and pull the final assistant text.
/// Mirrors DailyBriefingService's dispatch so every backend — including a
/// long-lived Hermes session — behaves identically.
enum OneShotAgentRunner {

    /// The user's chat backend, or nil when it isn't signed in / installed
    /// (callers surface that as "connect an agent backend first").
    static func usableBackend() -> AgentBackend? {
        switch AgentBackend.current {
        case .claude:
            return ClaudeAuthService.shared.effectiveAuthMode() != .none ? .claude : nil
        case .codex:
            return CodexAuthService.shared.effectiveAuthMode() != .none ? .codex : nil
        case .hermes:
            return HermesInstallation.binaryPath() != nil ? .hermes : nil
        }
    }

    static func run(
        backend: AgentBackend,
        sessionKey: UUID,
        userPrompt: String,
        systemPrompt: String,
        executor: OttoToolExecutor
    ) async throws -> String {
        let turns = [ChatTurn(role: "user", blocks: [.text(userPrompt)])]
        let result: [ChatTurn]
        switch backend {
        case .claude:
            result = try await ClaudeCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .codex:
            result = try await CodexCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .hermes:
            result = try await HermesAgentService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        }
        return finalAssistantText(result)
    }

    static func finalAssistantText(_ turns: [ChatTurn]) -> String {
        guard let last = turns.last(where: { $0.role == "assistant" }) else { return "" }
        return last.blocks.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    /// Lenient JSON extraction: slice from the first `{` to the last `}` so
    /// fenced or prose-wrapped payloads still decode.
    static func jsonSlice(of text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }
}
