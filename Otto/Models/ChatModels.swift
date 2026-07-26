import Foundation

/// A single message in a Otto chat session.
struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A file attached to a user chat turn. Sent to Claude as an `image` / `document` /
/// `text` content block depending on `kind`. Binary files we can't interpret
/// (xlsx etc.) are sent as a text stub with filename + size so Claude at least
/// knows they were attached.
struct ChatAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    let filename: String
    let mediaType: String   // e.g. "image/png", "application/pdf", "text/csv"
    let data: Data

    enum Kind {
        case image      // png / jpeg / gif / webp → image block (base64)
        case pdf        // → document block (base64)
        case text       // csv / txt / md / json → inlined as a text block
        case binary     // xlsx / unknown → filename-only stub
    }

    init(id: UUID = UUID(), filename: String, mediaType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.data = data
    }

    var kind: Kind {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return .image
        case "pdf":
            return .pdf
        case "csv", "txt", "md", "markdown", "json", "log", "tsv", "yaml", "yml", "xml", "html", "htm":
            return .text
        default:
            return .binary
        }
    }

    /// Markdown attachments render formatted (headings, bold, bullets) in
    /// previews; the rest of the text family shows as monospaced raw text.
    var isMarkdown: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// Decoded contents for `.text`-kind attachments (UTF-8 first, ISO-Latin-1
    /// fallback — same policy as FileStorageService). nil for binary kinds or
    /// undecodable data.
    var textContent: String? {
        guard kind == .text else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// MIME fallback for extensions whose UTType carries no preferred MIME
    /// type on a stock system (markdown's UTI is often dynamic).
    static func fallbackMediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "md", "markdown": return "text/markdown"
        case "tsv":            return "text/tab-separated-values"
        case "yaml", "yml":    return "application/yaml"
        case "log":            return "text/plain"
        default:               return "application/octet-stream"
        }
    }

    /// Anthropic image blocks only accept png/jpeg/gif/webp. HEIC → we don't
    /// re-encode here; the picker should pre-convert, or it'll fall back to binary.
    var imageMediaType: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"  // jpg / jpeg / heic (converted upstream)
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

/// A persisted chat session (list of messages). Stored in OttoDataStore as askHistory.
/// Kept around for backwards-compatibility with already-saved data; new chats
/// are saved as `ChatSession` so we don't lose tool-call detail.
struct AskHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String      // First user message, truncated
    var messages: [ChatMessage]
    let createdAt: Date

    init(id: UUID = UUID(), messages: [ChatMessage], createdAt: Date = Date()) {
        self.id = id
        self.messages = messages
        self.title = messages.first(where: { $0.role == "user" })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
            .description ?? "Chat"
        self.createdAt = createdAt
    }
}

/// Rich chat session — preserves the full `ChatTurn` log (text + tool calls
/// + results + attachments) so the conversation can be re-opened later
/// without losing context. Persisted via `OttoDataStore.chatSessions` and
/// browsed in the chat sheet's history sidebar.
struct ChatSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var turns: [ChatTurn]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String? = nil,
        turns: [ChatTurn] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title ?? Self.derivedTitle(from: turns)
    }

    /// Derive a short title from the first user message in the session. Falls
    /// back to a generic "New chat" if the session has no user text yet.
    static func derivedTitle(from turns: [ChatTurn]) -> String {
        for turn in turns where turn.role == "user" {
            for block in turn.blocks {
                if case let .text(s) = block {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(60))
                    }
                }
            }
        }
        return "New chat"
    }

    /// Re-derive the title from the current turns. Called when a turn list
    /// changes so the sidebar reflects the first prompt the user wrote.
    mutating func refreshTitle() {
        title = Self.derivedTitle(from: turns)
    }
}

// MARK: - Plain-text transcript flattening

/// Flattens turn logs into role-prefixed text for backends that re-feed
/// conversation history as prompt text: every Claude / Codex CLI run, and
/// the history replay that seeds a fresh Hermes ACP session after an app
/// restart.
///
/// Tool-use inputs and tool results ride along in compact bracketed form —
/// truncated, but present. Much of a conversation's substance lives only in
/// tool payloads (a `visualize` table, a `search_items` result), so a
/// text-only flatten made reopened conversations forget their own content.
enum ChatTranscript {
    /// Per-block caps keep one giant tool payload from eating the budget.
    private static let toolInputCap = 2_000
    private static let toolResultCap = 800
    /// Per-attachment inline cap — generous enough for a real README, small
    /// enough that one file can't eat the whole prompt (the conversation is
    /// re-flattened on every CLI run).
    private static let attachmentTextCap = 32_000

    /// Every turn, role-prefixed, blank-line separated. Empty turns dropped.
    static func flatten(_ turns: [ChatTurn]) -> String {
        turns.compactMap(flattenTurn).joined(separator: "\n\n")
    }

    /// One turn → "User: …" / "Assistant: …", or nil if it has no content.
    static func flattenTurn(_ turn: ChatTurn) -> String? {
        var pieces: [String] = []
        for block in turn.blocks {
            switch block {
            case .text(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            case .toolUse(_, let name, let input):
                pieces.append("[called \(name) with \(clip(compactJSON(input), toolInputCap))]")
            case .toolResult(_, let content, let isError):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                pieces.append("[\(isError ? "tool error" : "tool result"): \(clip(trimmed, toolResultCap))]")
            }
        }
        if let attachments = attachmentSection(turn.attachments) {
            pieces.append(attachments)
        }
        guard !pieces.isEmpty else { return nil }
        let role = turn.role == "assistant" ? "Assistant" : "User"
        return "\(role): \(pieces.joined(separator: "\n"))"
    }

    /// Prompt-side rendering of a turn's attachments — the only channel
    /// through which uploaded files reach the model (all three backends feed
    /// history as text). Text-family files (md / csv / txt / json…) are
    /// inlined verbatim inside labeled markers; binary kinds (images, PDFs,
    /// spreadsheets) become filename stubs so the model at least knows they
    /// were attached.
    static func attachmentSection(_ attachments: [ChatAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let pieces = attachments.map { a -> String in
            let size = ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)
            guard let text = a.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return "[Attached file: \(a.filename) (\(a.mediaType), \(size)) — content not inlined; ask the user to import it via the Files tab if you need to read it]"
            }
            var body = text
            var truncationNote = ""
            if body.count > attachmentTextCap {
                body = String(body.prefix(attachmentTextCap))
                truncationNote = "\n[…truncated — showing the first \(attachmentTextCap) of \(text.count) characters]"
            }
            return "[Attached file: \(a.filename) (\(a.mediaType), \(size))]\n\(body)\(truncationNote)\n[End of attached file: \(a.filename)]"
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    private static func compactJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value.anyValue,
            options: [.sortedKeys, .fragmentsAllowed]
        ), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Tool-calling chat types

/// Per-turn run telemetry, stamped onto the assistant `ChatTurn` by whichever
/// backend produced it. Duration + backend are always present; token counts
/// and cost only where the backend reports them (Claude/Codex CLI stream
/// usage events; the Hermes ACP stream has no usage frames).
struct TurnStats: Codable, Hashable {
    var durationMs: Int
    var backend: String        // AgentBackend rawValue
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?

    /// "12.4s · 8.1k tok · $0.04" — nil-safe compact caption for the UI.
    /// Tool-call count is derived from the turn's blocks by the caller.
    var caption: String {
        var parts: [String] = [String(format: "%.1fs", Double(durationMs) / 1000)]
        if let input = inputTokens, let output = outputTokens {
            let total = input + output
            parts.append(total >= 1000
                ? String(format: "%.1fk tok", Double(total) / 1000)
                : "\(total) tok")
        }
        if let cost = costUSD, cost > 0 {
            parts.append(cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost))
        }
        return parts.joined(separator: " · ")
    }
}

/// A full conversational turn — one role speaking once, potentially multiple content blocks
/// (text + tool calls + tool results). Mirrors Anthropic's messages[].content array.
struct ChatTurn: Identifiable, Codable, Hashable {
    let id: UUID
    let role: String          // "user" | "assistant"
    var blocks: [ChatBlock]
    var attachments: [ChatAttachment]
    let timestamp: Date
    /// Run telemetry — assistant turns only, and only for turns produced
    /// since stats capture shipped.
    var stats: TurnStats?

    init(
        id: UUID = UUID(),
        role: String,
        blocks: [ChatBlock],
        attachments: [ChatAttachment] = [],
        timestamp: Date = Date(),
        stats: TurnStats? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.attachments = attachments
        self.timestamp = timestamp
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, attachments, timestamp, stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(String.self, forKey: .role)
        self.blocks = try c.decode([ChatBlock].self, forKey: .blocks)
        self.attachments = (try? c.decode([ChatAttachment].self, forKey: .attachments)) ?? []
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.stats = try? c.decode(TurnStats.self, forKey: .stats)
    }
}

/// One content block inside a turn. Matches Anthropic's content-block types we care about.
enum ChatBlock: Codable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)

    private enum Kind: String, Codable { case text, toolUse, toolResult }

    private enum CodingKeys: String, CodingKey {
        case kind, text, id, name, input, toolUseId, content, isError
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode(String.self, forKey: .content),
                isError: (try? c.decode(Bool.self, forKey: .isError)) ?? false
            )
        }
    }
}

/// UI-level event emitted during a chat-with-tools run — lets the view render a live log.
enum ChatEvent {
    /// Finalized assistant text — the canonical version of one message
    /// segment, emitted after that segment's `.partialText` deltas. The UI
    /// uses it to settle the streaming bubble in place. Backends emit one
    /// per assistant message segment, so tool chips interleave between
    /// finalized bubbles (a turn with tool calls has several segments).
    case text(String)
    /// One streaming chunk of assistant text. Backends emit these as the
    /// model produces tokens; the UI accumulates them into the in-flight
    /// assistant bubble so the user sees the response unfold instead of
    /// just a spinner. For backends that don't stream per-token (e.g.
    /// Codex `exec --json`), this still fires once with the full message
    /// the moment it's available, giving an earlier visual signal than
    /// `.text` alone.
    case partialText(String)
    /// One streaming chunk of internal reasoning / "thinking" output from
    /// the model. Rendered as a dim, italic block above the assistant
    /// bubble so the user can follow the agent's thought process.
    case thinkingDelta(String)
    case toolCall(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, summary: String, isError: Bool)
    /// Hermes (ACP) only. The agent has asked permission to run a tool. The
    /// UI renders an inline approval card; the user's choice flows back via
    /// `HermesAgentService.resolveApproval(id:allow:)`. `argsSummary` is a
    /// short one-line description (e.g. "search_items query=\"groceries\"")
    /// safe to display.
    case approvalRequest(id: String, toolName: String, argsSummary: String)
    /// A degraded-turn warning the user should see (e.g. the MCP server
    /// failed to start, so Otto's tools are unavailable this turn). Rendered
    /// as a dim caption row in the transcript, not an error banner.
    case notice(String)
}

/// A small Codable wrapper for arbitrary JSON values (tool_use inputs).
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Convert a Foundation JSON value (from JSONSerialization) into a JSONValue.
    static func from(any: Any?) -> JSONValue {
        guard let any else { return .null }
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? Double { return .number(n) }
        if let n = any as? Int { return .number(Double(n)) }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map { JSONValue.from(any: $0) }) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = JSONValue.from(any: v) }
            return .object(out)
        }
        return .null
    }

    /// Convert back to a Foundation-friendly Any? for JSONSerialization.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.anyValue }
            return out
        }
    }

    var asDictionary: [String: Any]? {
        if case .object = self { return anyValue as? [String: Any] }
        return nil
    }
}
