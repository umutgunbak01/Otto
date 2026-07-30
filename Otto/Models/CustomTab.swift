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
    case calendar
    case dashboard

    var displayName: String {
        switch self {
        case .table: return "Table"
        case .board: return "Board"
        case .gallery: return "Gallery"
        case .list: return "List"
        case .calendar: return "Calendar"
        case .dashboard: return "Dashboard"
        }
    }

    var icon: String {
        switch self {
        case .table: return "tablecells"
        case .board: return "rectangle.split.3x1"
        case .gallery: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .calendar: return "calendar"
        case .dashboard: return "rectangle.3.group"
        }
    }
}

// MARK: - Tab Collection

/// One typed record set inside a custom tab. A tab holds 1..n collections —
/// "Boxing sessions" and "Meals" can live in the same tab, each with its own
/// columns, and dashboard `records` blocks / layout views target one
/// collection at a time.
struct TabCollection: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// snake_case identifier used as the agent tools' `collection` parameter
    /// and in workspace CSV names. Fixed at creation, unique within the tab.
    let key: String
    var fields: [CustomFieldDefinition]
    /// Board views' grouping column; must be `.singleSelect`. nil → first
    /// single-select field.
    var boardGroupFieldId: UUID?
    /// Calendar views' date column. nil → first `.date` field.
    var dateFieldId: UUID?
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        name: String,
        key: String,
        fields: [CustomFieldDefinition] = [],
        boardGroupFieldId: UUID? = nil,
        dateFieldId: UUID? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.fields = fields
        self.boardGroupFieldId = boardGroupFieldId
        self.dateFieldId = dateFieldId
        self.sortIndex = sortIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Items"
        key = (try? container.decode(String.self, forKey: .key)) ?? "items"
        fields = (try? container.decode([CustomFieldDefinition].self, forKey: .fields)) ?? []
        boardGroupFieldId = try? container.decode(UUID.self, forKey: .boardGroupFieldId)
        dateFieldId = try? container.decode(UUID.self, forKey: .dateFieldId)
        sortIndex = (try? container.decode(Int.self, forKey: .sortIndex)) ?? 0
    }

    var sortedFields: [CustomFieldDefinition] {
        fields.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// The collection's "title" column — the first field.
    var primaryField: CustomFieldDefinition? {
        sortedFields.first
    }

    /// The column board views group by: the configured field when it still
    /// exists and is a single-select, else the first single-select field.
    var boardGroupField: CustomFieldDefinition? {
        if let id = boardGroupFieldId,
           let field = fields.first(where: { $0.id == id && $0.kind == .singleSelect }) {
            return field
        }
        return sortedFields.first { $0.kind == .singleSelect }
    }

    /// The column calendar views place records by: the configured field when
    /// it still exists and is a date, else the first date field.
    var dateField: CustomFieldDefinition? {
        if let id = dateFieldId,
           let field = fields.first(where: { $0.id == id && $0.kind == .date }) {
            return field
        }
        return sortedFields.first { $0.kind == .date }
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

    /// snake_case key for a new collection, ≤24 chars, unique within the tab.
    static func makeKey(from name: String, existing: [TabCollection]) -> String {
        var base = String(CustomTabSlug.slugify(name).prefix(24))
        while base.hasSuffix("_") { base.removeLast() }
        if base.isEmpty { base = "items" }
        let taken = Set(existing.map(\.key))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }
}

// MARK: - Custom Tab Definition

/// A user-created tab: one or more `TabCollection` record sets plus optional
/// agent-composed dashboard `blocks`. Each tab is surfaced to the agent as a
/// `search_items` / `delete_item` type, generic record tools
/// (`add_tab_records` / `update_tab_record` with a `collection` param), a
/// generated `create_<slug>` / `update_<slug>` pair when it has exactly one
/// collection, and per-collection workspace CSVs.
struct CustomTabDefinition: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// snake_case identifier baked into tool names and the agent-facing type
    /// string. Fixed at creation (NOT re-derived on rename) so tool-approval
    /// preferences and chat history stay valid across renames.
    let slug: String
    /// SF Symbol shown in the sidebar.
    var icon: String
    var collections: [TabCollection]
    var sortIndex: Int
    let createdAt: Date
    /// Rendering style; `table` for tabs created before layouts existed.
    /// Non-dashboard layouts render one collection at a time (header chips
    /// switch between them); `dashboard` composes blocks.
    var layout: CustomTabLayout
    /// Optional one-line description under the tab title (agent-settable).
    var subtitle: String?
    /// Agent-composed dashboard blocks (rendered when `layout == .dashboard`).
    var blocks: [TabBlock]

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, icon, collections, sortIndex, createdAt, layout, subtitle, blocks
        // Pre-collections encoding (schema lived flat on the tab).
        case fields, boardGroupFieldId
    }

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
        self.init(
            id: id, name: name, slug: slug, icon: icon,
            collections: [TabCollection(id: id, name: "Items", key: "items", fields: fields, boardGroupFieldId: boardGroupFieldId)],
            sortIndex: sortIndex, createdAt: createdAt, layout: layout, subtitle: subtitle, blocks: blocks
        )
    }

    init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        icon: String = "tablecells",
        collections: [TabCollection],
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        layout: CustomTabLayout = .table,
        subtitle: String? = nil,
        blocks: [TabBlock] = []
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.icon = icon
        self.collections = collections
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.layout = layout
        self.subtitle = subtitle
        self.blocks = blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        icon = (try? container.decode(String.self, forKey: .icon)) ?? "tablecells"
        sortIndex = (try? container.decode(Int.self, forKey: .sortIndex)) ?? 0
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        layout = (try? container.decode(CustomTabLayout.self, forKey: .layout)) ?? .table
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        blocks = (try? container.decode([TabBlock].self, forKey: .blocks)) ?? []
        if let decoded = try? container.decode([TabCollection].self, forKey: .collections), !decoded.isEmpty {
            collections = decoded
        } else {
            // Pre-collections tab: lift the flat schema into one collection.
            // Its id deliberately equals the tab id — deterministic across
            // launches, so legacy records (nil collectionId) resolve stably.
            let legacyFields = (try? container.decode([CustomFieldDefinition].self, forKey: .fields)) ?? []
            let legacyGroup = try? container.decode(UUID.self, forKey: .boardGroupFieldId)
            collections = [TabCollection(id: id, name: "Items", key: "items", fields: legacyFields, boardGroupFieldId: legacyGroup)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(icon, forKey: .icon)
        try container.encode(collections, forKey: .collections)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(layout, forKey: .layout)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(blocks, forKey: .blocks)
    }

    // MARK: Collection lookup

    var sortedCollections: [TabCollection] {
        collections.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Match a tool `collection` param: exact key, case-insensitive name, or
    /// slugified name.
    func collection(matching raw: String) -> TabCollection? {
        let needle = raw.trimmingCharacters(in: .whitespaces)
        let lowered = needle.lowercased()
        if let c = collections.first(where: { $0.key == lowered }) { return c }
        if let c = collections.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) { return c }
        let slugged = CustomTabSlug.slugify(needle)
        guard !slugged.isEmpty else { return nil }
        return collections.first { CustomTabSlug.slugify($0.name) == slugged || $0.key == slugged }
    }

    /// The collection a record belongs to. Legacy records (nil collectionId)
    /// resolve to the collection whose id equals the tab id (the lifted
    /// pre-collections schema), else the first collection.
    func collection(for record: CustomRecord) -> TabCollection? {
        if let cid = record.collectionId, let c = collections.first(where: { $0.id == cid }) {
            return c
        }
        return collections.first(where: { $0.id == id }) ?? sortedCollections.first
    }

    // MARK: First-collection conveniences
    //
    // Single-collection tabs are the common case; these keep their call sites
    // (generated per-tab tools, legacy views, the sidebar) reading naturally.

    /// The first collection's columns. Setter writes through — used by the
    /// tab editor and schema tools when the tab has one collection.
    var fields: [CustomFieldDefinition] {
        get { sortedCollections.first?.fields ?? [] }
        set {
            if let first = sortedCollections.first,
               let index = collections.firstIndex(where: { $0.id == first.id }) {
                collections[index].fields = newValue
            } else {
                collections = [TabCollection(id: id, name: "Items", key: "items", fields: newValue)]
            }
        }
    }

    var sortedFields: [CustomFieldDefinition] {
        sortedCollections.first?.sortedFields ?? []
    }

    /// The first collection's "title" column.
    var primaryField: CustomFieldDefinition? {
        sortedCollections.first?.primaryField
    }

    var boardGroupField: CustomFieldDefinition? {
        sortedCollections.first?.boardGroupField
    }

    /// Tool-input keys for the first collection (the generated
    /// `create_<slug>` / `update_<slug>` tools' schema).
    func fieldKeys() -> [(key: String, field: CustomFieldDefinition)] {
        sortedCollections.first?.fieldKeys() ?? []
    }

    /// Every field across every collection — orphan-value cleanup and
    /// record migration use this.
    var allFieldIds: Set<UUID> {
        Set(collections.flatMap { $0.fields.map(\.id) })
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
        "saved_prompt", "scheduled_task",
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
    /// Owning collection within the tab. nil on records persisted before
    /// collections existed — AppState stamps those to the tab's legacy
    /// collection at load.
    var collectionId: UUID?
    var values: [UUID: CustomFieldValue]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        tabId: UUID,
        collectionId: UUID? = nil,
        values: [UUID: CustomFieldValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tabId = tabId
        self.collectionId = collectionId
        self.values = values
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabId, collectionId, values, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tabId = try container.decode(UUID.self, forKey: .tabId)
        collectionId = try? container.decode(UUID.self, forKey: .collectionId)
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
        try container.encodeIfPresent(collectionId, forKey: .collectionId)
        let stringKeyed = Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) })
        try container.encode(stringKeyed, forKey: .values)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Display title: the owning collection's primary (first) field value,
    /// or "Untitled".
    func displayTitle(in tab: CustomTabDefinition) -> String {
        guard let primary = tab.collection(for: self)?.primaryField,
              let value = values[primary.id] else { return "Untitled" }
        let text = value.displayString(for: primary)
        return text.isEmpty ? "Untitled" : text
    }

    /// Every value flattened to text — feeds search_items matching. Includes
    /// the collection name so "boxing" finds boxing-session rows by set name.
    func searchableText(in tab: CustomTabDefinition) -> String {
        guard let collection = tab.collection(for: self) else { return "" }
        var parts = collection.sortedFields
            .compactMap { field in values[field.id]?.displayString(for: field) }
        if tab.collections.count > 1 { parts.append(collection.name) }
        return parts.joined(separator: " ")
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
