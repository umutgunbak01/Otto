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
        case "csv", "txt", "md", "json", "log", "tsv", "yaml", "yml", "xml", "html", "htm":
            return .text
        default:
            return .binary
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

// MARK: - Tool-calling chat types

/// A full conversational turn — one role speaking once, potentially multiple content blocks
/// (text + tool calls + tool results). Mirrors Anthropic's messages[].content array.
struct ChatTurn: Identifiable, Codable, Hashable {
    let id: UUID
    let role: String          // "user" | "assistant"
    var blocks: [ChatBlock]
    var attachments: [ChatAttachment]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: String,
        blocks: [ChatBlock],
        attachments: [ChatAttachment] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.attachments = attachments
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, attachments, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(String.self, forKey: .role)
        self.blocks = try c.decode([ChatBlock].self, forKey: .blocks)
        self.attachments = (try? c.decode([ChatAttachment].self, forKey: .attachments)) ?? []
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
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
    case text(String)
    case toolCall(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, summary: String, isError: Bool)
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
