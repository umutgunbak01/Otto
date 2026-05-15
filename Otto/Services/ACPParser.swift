import Foundation

/// Pure JSON-RPC + ACP (Agent Client Protocol) parser. No I/O, no Process,
/// no actor state — fully testable. `HermesAgentService` wraps a `Process`
/// running `hermes acp` and feeds its stdout into `ACPParser.parse(line:)`,
/// then translates the resulting `ACPMessage`s into Otto `ChatEvent`s.
///
/// Protocol shape (ACP v1):
///   • Client → Agent requests:
///       - `initialize`         — capabilities handshake
///       - `session/new`        — create a session, get back a sessionId
///       - `session/prompt`     — send a user turn; response carries `stopReason`
///   • Agent → Client notifications:
///       - `session/update`     — discriminated by `params.update.sessionUpdate`
///   • Agent → Client requests:
///       - `session/request_permission` — agent asks before running a tool;
///                                        client must respond with an outcome.
///
/// See https://agentclientprotocol.com/protocol/ for the full spec.
enum ACPParser {

    // MARK: - Top-level message shapes

    /// One parsed JSON-RPC frame from the agent. `unknown` covers methods or
    /// shapes we don't model yet — we log and drop those rather than crashing.
    enum Message {
        /// `session/update` notification — discriminated by the inner `sessionUpdate` field.
        case sessionUpdate(SessionUpdate)
        /// `session/request_permission` request from the agent. We must respond
        /// with an `outcome` keyed by this request's `id`.
        case requestPermission(id: JSONRPCID, sessionId: String, toolCallId: String, options: [PermissionOption])
        /// A response to one of *our* requests (`initialize`, `session/new`,
        /// `session/prompt`). `id` matches the request we sent.
        case response(id: JSONRPCID, result: [String: Any]?, error: ACPError?)
        /// Anything we don't model. Caller may log + drop.
        case unknown
    }

    /// JSON-RPC `id` can be a string OR a number. We keep both shapes so
    /// outbound responses echo the same type back.
    enum JSONRPCID: Hashable {
        case int(Int)
        case string(String)

        var asAny: Any {
            switch self {
            case .int(let i):    return i
            case .string(let s): return s
            }
        }

        static func from(_ any: Any?) -> JSONRPCID? {
            if let i = any as? Int { return .int(i) }
            if let d = any as? Double { return .int(Int(d)) }
            if let s = any as? String { return .string(s) }
            return nil
        }
    }

    /// `params.update.sessionUpdate` discriminator → typed payload.
    enum SessionUpdate {
        /// Streaming assistant text. Each frame carries one chunk.
        case agentMessageChunk(text: String)
        /// Streaming reasoning / "thinking". Same shape as message chunks.
        case agentThoughtChunk(text: String)
        /// Tool invocation announced (`status: "pending"` typically). We use
        /// this to populate the chat "🔧 calling X" chip.
        case toolCall(toolCallId: String, title: String, kind: String?)
        /// Tool finished — `status` is `completed` or `failed`. `contentSummary`
        /// is a flattened one-liner from the inner content array.
        case toolCallUpdate(toolCallId: String, status: String, contentSummary: String, isError: Bool)
        /// Anything else (`plan`, etc.) we don't render yet.
        case unknown
    }

    struct PermissionOption {
        let optionId: String
        let name: String
        /// `allow_once` / `allow_always` / `reject_once` / `reject_always`. We
        /// don't actually need to look at this — Otto computes its own decision
        /// from `ToolApprovalPolicy` and picks the matching optionId — but we
        /// keep it for potential future logic.
        let kind: String
    }

    struct ACPError: Error {
        let code: Int
        let message: String
    }

    // MARK: - Parsing

    /// Parse one newline-delimited JSON-RPC frame from the agent's stdout.
    /// Returns `nil` only on truly garbage input (not valid JSON, no `jsonrpc`
    /// field); valid JSON with an unmodeled shape comes back as `.unknown`.
    static func parse(line: String) -> Message? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let method = obj["method"] as? String
        let id = JSONRPCID.from(obj["id"])

        // Responses to our requests: id present, no method, result or error present.
        if method == nil, let id = id {
            if let result = obj["result"] as? [String: Any] {
                return .response(id: id, result: result, error: nil)
            }
            if let errObj = obj["error"] as? [String: Any] {
                let code = errObj["code"] as? Int ?? -1
                let message = errObj["message"] as? String ?? "(no message)"
                return .response(id: id, result: nil, error: ACPError(code: code, message: message))
            }
            return .response(id: id, result: nil, error: nil)
        }

        // Requests/notifications from the agent.
        guard let method = method else { return .unknown }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            return .sessionUpdate(parseSessionUpdate(params))

        case "session/request_permission":
            guard let id = id,
                  let sessionId = params["sessionId"] as? String,
                  let toolCall = params["toolCall"] as? [String: Any],
                  let toolCallId = toolCall["toolCallId"] as? String
            else { return .unknown }
            let rawOptions = params["options"] as? [[String: Any]] ?? []
            let options: [PermissionOption] = rawOptions.compactMap { opt in
                guard let optionId = opt["optionId"] as? String,
                      let name = opt["name"] as? String
                else { return nil }
                return PermissionOption(
                    optionId: optionId,
                    name: name,
                    kind: (opt["kind"] as? String) ?? ""
                )
            }
            return .requestPermission(
                id: id,
                sessionId: sessionId,
                toolCallId: toolCallId,
                options: options
            )

        default:
            return .unknown
        }
    }

    private static func parseSessionUpdate(_ params: [String: Any]) -> SessionUpdate {
        guard let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String
        else { return .unknown }

        switch kind {
        case "agent_message_chunk":
            return .agentMessageChunk(text: extractContentText(update["content"]))

        case "agent_thought_chunk":
            return .agentThoughtChunk(text: extractContentText(update["content"]))

        case "tool_call":
            guard let id = update["toolCallId"] as? String else { return .unknown }
            let title = update["title"] as? String ?? "tool"
            let kindStr = update["kind"] as? String
            return .toolCall(toolCallId: id, title: title, kind: kindStr)

        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return .unknown }
            let status = update["status"] as? String ?? ""
            let isError = (status == "failed")
            let summary = extractToolResultSummary(update["content"])
            return .toolCallUpdate(toolCallId: id, status: status, contentSummary: summary, isError: isError)

        default:
            return .unknown
        }
    }

    /// `content` in an `agent_message_chunk` is either a single `{type:"text",text:"…"}`
    /// or an array of them. Flatten to a string.
    private static func extractContentText(_ value: Any?) -> String {
        if let obj = value as? [String: Any] {
            return (obj["text"] as? String) ?? ""
        }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// `content` in a `tool_call_update` is an array of `{type:"content", content:{type,text}}`
    /// wrappers. Flatten the inner texts into a single line for the chip.
    private static func extractToolResultSummary(_ value: Any?) -> String {
        guard let arr = value as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for item in arr {
            if let inner = item["content"] as? [String: Any],
               let text = inner["text"] as? String {
                pieces.append(text)
            } else if let text = item["text"] as? String {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Outbound JSON-RPC builders

    /// Initialize request — declares Otto's client capabilities and protocol version.
    static func initializeRequest(id: JSONRPCID) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id.asAny,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": [
                    // Otto doesn't expose its own filesystem to the agent — all
                    // file access goes through the otto MCP server (read_file
                    // tool). Same for terminal — no remote shell access.
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ],
                "clientInfo": [
                    "name": "otto",
                    "title": "Otto",
                    "version": "1.0.0"
                ]
            ] as [String: Any]
        ]
    }

    /// Create a new ACP session. The `mcpServers` array is empty here because
    /// the user's `~/.hermes/config.yaml` already configures the `otto` MCP
    /// server entry pointing at Otto's local Unix socket.
    static func newSessionRequest(id: JSONRPCID, cwd: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id.asAny,
            "method": "session/new",
            "params": [
                "cwd": cwd,
                "mcpServers": [[String: Any]]()
            ] as [String: Any]
        ]
    }

    /// Send a user turn. `prompt` is an array of content blocks; v1 only
    /// sends text content. Screen-vision goes via the `read_file` MCP tool
    /// (Hermes reads a path Otto has staged), not via inlined image blocks.
    static func promptRequest(id: JSONRPCID, sessionId: String, text: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id.asAny,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionId,
                "prompt": [
                    ["type": "text", "text": text] as [String: Any]
                ]
            ] as [String: Any]
        ]
    }

    /// Response to a `session/request_permission` request. `optionId` is the
    /// chosen option's id (the agent sent us a list of options). When the user
    /// dismisses without choosing, send a `cancelled` outcome instead.
    static func permissionResponse(id: JSONRPCID, selectedOptionId: String?) -> [String: Any] {
        let outcome: [String: Any]
        if let optionId = selectedOptionId {
            outcome = ["outcome": "selected", "optionId": optionId]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        return [
            "jsonrpc": "2.0",
            "id": id.asAny,
            "result": ["outcome": outcome]
        ]
    }
}
