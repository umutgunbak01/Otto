import Foundation

// MARK: - Custom Tab Layout

/// How a custom tab renders its content. `table`/`board`/`gallery`/`list`
/// are views over the tab's records; `dashboard` renders the tab's agent-
/// composed `blocks` (which can embed the records via a `records` block).
enum CustomTabLayout: String, Codable, CaseIterable, Hashable {
    case table
    case board
    case gallery
    case list
    case dashboard

    var displayName: String {
        switch self {
        case .table: return "Table"
        case .board: return "Board"
        case .gallery: return "Gallery"
        case .list: return "List"
        case .dashboard: return "Dashboard"
        }
    }

    var icon: String {
        switch self {
        case .table: return "tablecells"
        case .board: return "rectangle.split.3x1"
        case .gallery: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .dashboard: return "rectangle.3.group"
        }
    }
}

// MARK: - Custom Tab Definition

/// A user-created tab: a named table whose columns are `CustomFieldDefinition`s
/// (same typed-field model the Connections CRM columns use). Each tab is also
/// surfaced to the agent as a pair of generated tools (`create_<slug>` /
/// `update_<slug>`), a `search_items` / `delete_item` type, and a
/// `custom_<slug>.csv` workspace table.
struct CustomTabDefinition: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// snake_case identifier baked into tool names and the agent-facing type
    /// string. Fixed at creation (NOT re-derived on rename) so tool-approval
    /// preferences and chat history stay valid across renames.
    let slug: String
    /// SF Symbol shown in the sidebar.
    var icon: String
    var fields: [CustomFieldDefinition]
    var sortIndex: Int
    let createdAt: Date
    /// Rendering style; `table` for tabs created before layouts existed.
    var layout: CustomTabLayout
    /// Optional one-line description under the tab title (agent-settable).
    var subtitle: String?
    /// Board layout's grouping column; must be a `.singleSelect` field.
    /// nil → first single-select field.
    var boardGroupFieldId: UUID?
    /// Agent-composed dashboard blocks (rendered when `layout == .dashboard`).
    var blocks: [TabBlock]

    init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        icon: String = "tablecells",
        fields: [CustomFieldDefinition] = [],
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        layout: CustomTabLayout = .table,
        subtitle: String? = nil,
        boardGroupFieldId: UUID? = nil,
        blocks: [TabBlock] = []
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.icon = icon
        self.fields = fields
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.layout = layout
        self.subtitle = subtitle
        self.boardGroupFieldId = boardGroupFieldId
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        icon = (try? container.decode(String.self, forKey: .icon)) ?? "tablecells"
        fields = (try? container.decode([CustomFieldDefinition].self, forKey: .fields)) ?? []
        sortIndex = (try? container.decode(Int.self, forKey: .sortIndex)) ?? 0
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        layout = (try? container.decode(CustomTabLayout.self, forKey: .layout)) ?? .table
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        boardGroupFieldId = try? container.decode(UUID.self, forKey: .boardGroupFieldId)
        blocks = (try? container.decode([TabBlock].self, forKey: .blocks)) ?? []
    }

    var sortedFields: [CustomFieldDefinition] {
        fields.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The tab's "title" column — the first field. Rendered as the record's
    /// display title in search results, tool summaries, and the sidebar.
    var primaryField: CustomFieldDefinition? {
        sortedFields.first
    }

    /// The column board layouts group by: the configured field when it still
    /// exists and is a single-select, else the first single-select field.
    var boardGroupField: CustomFieldDefinition? {
        if let id = boardGroupFieldId,
           let field = fields.first(where: { $0.id == id && $0.kind == .singleSelect }) {
            return field
        }
        return sortedFields.first { $0.kind == .singleSelect }
    }

    /// Stable (toolInputKey, field) pairs for the generated tool schemas and
    /// the executor's input parsing. Keys are the snake_cased field names,
    /// de-duplicated in column order ("status", "status_2", …) so two fields
    /// that slugify identically can't collide.
    func fieldKeys() -> [(key: String, field: CustomFieldDefinition)] {
        var used = Set<String>()
        var out: [(String, CustomFieldDefinition)] = []
        for field in sortedFields {
            var key = CustomTabSlug.slugify(field.name)
            if key.isEmpty { key = "field" }
            if used.contains(key) {
                var n = 2
                while used.contains("\(key)_\(n)") { n += 1 }
                key = "\(key)_\(n)"
            }
            used.insert(key)
            out.append((key, field))
        }
        return out
    }
}

// MARK: - Slug generation

enum CustomTabSlug {
    /// Type strings and tool-name suffixes already taken by built-in tabs and
    /// tools. A custom tab whose name slugifies into one of these gets a
    /// `_tab` suffix so `create_<slug>` / `delete_item(type:)` never collide.
    static let reserved: Set<String> = [
        // Built-in search/delete/get type strings.
        "todo", "note", "idea", "reminder", "bookmark", "meeting", "email",
        "connection", "network", "company", "event", "community", "habit",
        "file", "x_post", "x_follower", "x_dm",
        // Tool-name suffixes that would collide with existing create_*/update_* tools.
        "network_entry",
        // Other tool-name tails (delete_item, search_items, grep_data, open_url, read_file).
        "item", "items", "data", "url"
    ]

    /// Lowercase ASCII, non-alphanumerics collapsed to single underscores.
    /// Diacritics fold (Café → cafe); anything still non-ASCII is dropped —
    /// tool names must match the API's ^[a-zA-Z0-9_-]{1,64}$, and "create_"
    /// takes 7 of those chars, so the slug is capped at 48.
    static func slugify(_ name: String) -> String {
        let folded = name
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
        var out = ""
        var lastWasUnderscore = true // suppress leading underscore
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        out = String(out.prefix(48))
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    /// Unique slug for a new tab: slugified name, `_tab`-suffixed if reserved,
    /// numbered if another tab already claimed it.
    static func make(from name: String, existing: [CustomTabDefinition]) -> String {
        var base = slugify(name)
        if base.isEmpty { base = "tab" }
        if reserved.contains(base) { base += "_tab" }
        let taken = Set(existing.map(\.slug))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }
}

// MARK: - Custom Record

/// One row in a custom tab. Values are keyed by `CustomFieldDefinition.id`
/// (stable across field renames), same shape as `Connection.customFields`.
struct CustomRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    var values: [UUID: CustomFieldValue]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        tabId: UUID,
        values: [UUID: CustomFieldValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tabId = tabId
        self.values = values
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabId, values, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabId = try container.decode(UUID.self, forKey: .tabId)
        // UUID-keyed dictionaries encode as flat arrays in JSON — store
        // string-keyed instead (same workaround as Connection.customFields).
        if let stringKeyed = try? container.decode([String: CustomFieldValue].self, forKey: .values) {
            values = Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        } else {
            values = [:]
        }
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tabId, forKey: .tabId)
        let stringKeyed = Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) })
        try container.encode(stringKeyed, forKey: .values)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Display title: the primary (first) field's value, or "Untitled".
    func displayTitle(in tab: CustomTabDefinition) -> String {
        guard let primary = tab.primaryField,
              let value = values[primary.id] else { return "Untitled" }
        let text = value.displayString(for: primary)
        return text.isEmpty ? "Untitled" : text
    }

    /// Every value flattened to text — feeds search_items matching.
    func searchableText(in tab: CustomTabDefinition) -> String {
        tab.sortedFields
            .compactMap { field in values[field.id]?.displayString(for: field) }
            .joined(separator: " ")
    }
}

// MARK: - Value ↔ text / tool-input bridging

extension CustomFieldValue {
    /// Human-readable rendering, resolving option ids through the definition.
    /// Used by the table cells' fallback text, search, the workspace CSV, and
    /// tool results.
    func displayString(for definition: CustomFieldDefinition) -> String {
        switch self {
        case .text(let s), .url(let s):
            return s
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .date(let d):
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = .current
            let iso = f.string(from: d)
            // Date-only when the time component is midnight local — keeps CSV
            // rows and chat output readable for plain dates.
            return iso.hasSuffix("T00:00:00" + String(iso.suffix(6))) ? String(iso.prefix(10)) : iso
        case .bool(let b):
            return b ? "yes" : "no"
        case .optionIds(let ids):
            return ids.compactMap { id in definition.options.first(where: { $0.id == id })?.label }
                .joined(separator: "|")
        }
    }
}

/// Thrown by `CustomFieldValue.fromToolInput` with an agent-facing message.
struct CustomFieldInputError: Error {
    let message: String
}

extension CustomFieldValue {
    /// Parse a raw JSON tool-input value against a field definition. Returns
    /// nil when the input explicitly clears the value (empty string / empty
    /// array / false checkbox). Throws with a corrective message on type or
    /// option-label mismatches so the agent can retry.
    static func fromToolInput(_ raw: Any, field: CustomFieldDefinition) throws -> CustomFieldValue? {
        switch field.kind {
        case .text, .longText, .url:
            guard let s = raw as? String else {
                throw CustomFieldInputError(message: "Field '\(field.name)' expects a string.")
            }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (field.kind == .url ? .url(trimmed) : .text(trimmed))

        case .number:
            if let n = raw as? NSNumber { return .number(n.doubleValue) }
            if let s = raw as? String, let n = Double(s.trimmingCharacters(in: .whitespaces)) {
                return .number(n)
            }
            throw CustomFieldInputError(message: "Field '\(field.name)' expects a number.")

        case .date:
            guard let s = raw as? String else {
                throw CustomFieldInputError(message: "Field '\(field.name)' expects an ISO8601 date string.")
            }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if let d = parseISODate(trimmed) { return .date(d) }
            throw CustomFieldInputError(message: "Field '\(field.name)': couldn't parse '\(trimmed)' as ISO8601 (use e.g. 2026-07-08 or 2026-07-08T17:00:00Z).")

        case .checkbox:
            if let b = raw as? Bool { return b ? .bool(true) : nil }
            throw CustomFieldInputError(message: "Field '\(field.name)' expects a boolean.")

        case .singleSelect:
            guard let s = raw as? String else {
                throw CustomFieldInputError(message: "Field '\(field.name)' expects one of: \(field.options.map(\.label).joined(separator: ", ")).")
            }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            guard let option = field.option(matching: trimmed) else {
                throw CustomFieldInputError(message: "Field '\(field.name)': unknown option '\(trimmed)'. Valid options: \(field.options.map(\.label).joined(separator: ", ")).")
            }
            return .optionIds([option.id])

        case .multiSelect:
            let labels: [String]
            if let arr = raw as? [String] {
                labels = arr
            } else if let s = raw as? String {
                // Tolerate a single string or "a|b" for multi-selects.
                labels = s.split(separator: "|").map(String.init)
            } else {
                throw CustomFieldInputError(message: "Field '\(field.name)' expects an array of option labels.")
            }
            var ids: [UUID] = []
            for label in labels {
                let trimmed = label.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let option = field.option(matching: trimmed) else {
                    throw CustomFieldInputError(message: "Field '\(field.name)': unknown option '\(trimmed)'. Valid options: \(field.options.map(\.label).joined(separator: ", ")).")
                }
                if !ids.contains(option.id) { ids.append(option.id) }
            }
            return ids.isEmpty ? nil : .optionIds(ids)
        }
    }

    /// JSON-encodable value for `get_item` / search payloads.
    func toolOutputValue(for definition: CustomFieldDefinition) -> Any {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b
        case .optionIds(let ids) where definition.kind == .multiSelect:
            return ids.compactMap { id in definition.options.first(where: { $0.id == id })?.label }
        default:
            return displayString(for: definition)
        }
    }

    private static func parseISODate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        // Date-only ("2026-07-08") → midnight local time.
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        dayOnly.timeZone = .current
        return dayOnly.date(from: s)
    }
}

extension CustomFieldDefinition {
    /// Case-insensitive option lookup by label.
    func option(matching label: String) -> CustomFieldOption? {
        options.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }
}
