import Foundation

// MARK: - Tab Block (generative dashboard unit)

/// One agent-composable block on a custom tab's dashboard. The payload is
/// stored as raw `JSONValue` (same trick as `visualize` tool calls persisting
/// their spec) so new block shapes stay forward-compatible; it's validated
/// once at write time via `TabBlock.make` and parsed leniently at render
/// time via `TabBlockContent.parse`.
struct TabBlock: Codable, Identifiable, Hashable {
    /// Agent-chosen slug ("standings", "summary") so `update_tab_block`
    /// can patch one block in place. Generated when the agent omits it.
    let id: String
    var json: JSONValue
    var updatedAt: Date

    init(id: String, json: JSONValue, updatedAt: Date = Date()) {
        self.id = id
        self.json = json
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        json = (try? container.decode(JSONValue.self, forKey: .json)) ?? .object([:])
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    var title: String? {
        guard let dict = json.asDictionary,
              let t = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    var typeName: String {
        (json.asDictionary?["type"] as? String)?.lowercased() ?? "?"
    }

    /// Validate an agent-supplied block object and mint the stored block.
    /// Throws `TabBlockError` with a corrective, agent-facing message.
    static func make(from raw: Any, fallbackId: String) throws -> TabBlock {
        guard let dict = raw as? [String: Any] else {
            throw TabBlockError("Each block must be a JSON object with a \"type\".")
        }
        // Parse now so a malformed block is rejected at write time with a
        // useful error instead of rendering as an error card later.
        _ = try TabBlockContent.parse(dict)
        var id = ((dict["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if id.isEmpty { id = fallbackId }
        id = CustomTabSlug.slugify(id)
        if id.isEmpty { id = fallbackId }
        return TabBlock(id: id, json: JSONValue.from(any: dict))
    }
}

struct TabBlockError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Parsed render model

/// A `TabBlock`'s payload decoded for rendering. Chart-ish kinds (stats,
/// table, bar, line, pie) delegate wholesale to `VisualizationSpec`, so
/// dashboards and chat `visualize` cards render identically.
enum TabBlockContent {
    case viz(VisualizationSpec)
    case markdown(String)
    case progress([ProgressItem])
    case list(style: ListStyle, items: [ListItem])
    case timeline([TimelineItem])
    case records(RecordsConfig)

    struct ProgressItem {
        var label: String
        var value: Double
        /// Denominator; bars render value/target. Defaults to 100 ("percent").
        var target: Double
        /// Named color ("green") or "#RRGGBB"; nil → accent.
        var color: String?
        var detail: String?
    }

    enum ListStyle: String {
        case bullet, number, check
    }

    struct ListItem {
        var text: String
        var done: Bool
        var note: String?
        /// Index into the block json's raw `items` array — checklist toggles
        /// write back through this so skipped/malformed siblings can't shift
        /// the target.
        var originalIndex: Int
    }

    struct TimelineItem {
        var date: String
        var title: String
        var detail: String?
    }

    /// Live embed of the tab's own records inside a dashboard.
    struct RecordsConfig {
        var view: CustomTabLayout   // .table / .list / .board / .gallery
        var limit: Int?
        var title: String?
    }

    static let typeNames = [
        "markdown", "stats", "table", "bar", "line", "pie",
        "progress", "list", "timeline", "records"
    ]

    /// Parse a raw block object. Throws `TabBlockError` with the same
    /// corrective tone as `VisualizationSpec.ParseError`.
    static func parse(_ dict: [String: Any]) throws -> TabBlockContent {
        let type = ((dict["type"] as? String) ?? "").lowercased()
        switch type {
        case "stats", "table", "bar", "line", "pie":
            do {
                return .viz(try VisualizationSpec.parse(dict))
            } catch let e as VisualizationSpec.ParseError {
                throw TabBlockError(e.message)
            }

        case "markdown", "text":
            guard let content = dict["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TabBlockError("type='markdown' requires non-empty 'content' (markdown string).")
            }
            return .markdown(content)

        case "progress":
            let rawItems = (dict["items"] as? [Any]) ?? []
            let items: [ProgressItem] = rawItems.compactMap { raw in
                guard let d = raw as? [String: Any],
                      let label = (d["label"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !label.isEmpty,
                      let value = doubleValue(d["value"]) else { return nil }
                let target = doubleValue(d["target"]) ?? 100
                return ProgressItem(
                    label: label,
                    value: value,
                    target: max(target, 0.0001),
                    color: (d["color"] as? String)?.trimmingCharacters(in: .whitespaces),
                    detail: cleanString(d["detail"])
                )
            }
            guard !items.isEmpty else {
                throw TabBlockError("type='progress' requires 'items' — [{label, value, target? (default 100), color?, detail?}].")
            }
            return .progress(Array(items.prefix(20)))

        case "list":
            let style = ListStyle(rawValue: ((dict["style"] as? String) ?? "bullet").lowercased()) ?? .bullet
            let rawItems = (dict["items"] as? [Any]) ?? []
            let items: [ListItem] = rawItems.enumerated().compactMap { index, raw in
                if let s = raw as? String {
                    let t = s.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : ListItem(text: t, done: false, note: nil, originalIndex: index)
                }
                guard let d = raw as? [String: Any],
                      let text = (d["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty else { return nil }
                return ListItem(
                    text: text,
                    done: (d["done"] as? Bool) ?? false,
                    note: cleanString(d["note"]),
                    originalIndex: index
                )
            }
            guard !items.isEmpty else {
                throw TabBlockError("type='list' requires 'items' — [{text, done?, note?}] (or plain strings). Optional style: bullet|number|check.")
            }
            return .list(style: style, items: Array(items.prefix(100)))

        case "timeline":
            let rawItems = (dict["items"] as? [Any]) ?? []
            let items: [TimelineItem] = rawItems.compactMap { raw in
                guard let d = raw as? [String: Any],
                      let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty else { return nil }
                let date = ((d["date"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                return TimelineItem(date: date, title: title, detail: cleanString(d["detail"]))
            }
            guard !items.isEmpty else {
                throw TabBlockError("type='timeline' requires 'items' — [{date, title, detail?}].")
            }
            return .timeline(Array(items.prefix(60)))

        case "records":
            let viewRaw = ((dict["view"] as? String) ?? "table").lowercased()
            guard let view = CustomTabLayout(rawValue: viewRaw), view != .dashboard else {
                throw TabBlockError("type='records' 'view' must be one of: table, list, board, gallery.")
            }
            var limit: Int?
            if let l = dict["limit"] as? Int { limit = max(1, min(l, 500)) }
            else if let l = doubleValue(dict["limit"]) { limit = max(1, min(Int(l), 500)) }
            return .records(RecordsConfig(view: view, limit: limit, title: cleanString(dict["title"])))

        default:
            throw TabBlockError("Unknown block type '\(type)'. Valid types: \(typeNames.joined(separator: ", ")).")
        }
    }

    /// Render-time entry point: parse the persisted JSON, nil on failure
    /// (the view shows a fallback card naming the block).
    static func parse(block: TabBlock) -> TabBlockContent? {
        guard let dict = block.json.asDictionary else { return nil }
        return try? parse(dict)
    }

    // MARK: helpers

    private static func cleanString(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String:
            let cleaned = s.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        default: return nil
        }
    }
}

// MARK: - Block colors

enum TabBlockColor {
    /// Named palette the tools document; falls back to `#RRGGBB` passthrough.
    /// Hexes match `CustomFieldOptionPalette` so select chips and progress
    /// bars share one accent language.
    static let named: [String: String] = [
        "red": "#EF5350", "orange": "#FF7043", "yellow": "#FFCA28",
        "amber": "#FFCA28", "green": "#66BB6A", "teal": "#26C6DA",
        "cyan": "#26C6DA", "blue": "#42A5F5", "purple": "#7E57C2",
        "violet": "#7E57C2", "pink": "#EC407A"
    ]

    static func hex(for raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { return raw }
        return named[raw]
    }
}
