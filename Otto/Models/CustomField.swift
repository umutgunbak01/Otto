import Foundation
import SwiftUI

// MARK: - Custom Field Kind

enum CustomFieldKind: String, Codable, CaseIterable, Hashable {
    case text
    case longText
    case number
    case date
    case checkbox
    case url
    case singleSelect
    case multiSelect

    var label: String {
        switch self {
        case .text: return "Text"
        case .longText: return "Long text"
        case .number: return "Number"
        case .date: return "Date"
        case .checkbox: return "Checkbox"
        case .url: return "URL"
        case .singleSelect: return "Single select"
        case .multiSelect: return "Multi select"
        }
    }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .longText: return "text.alignleft"
        case .number: return "number"
        case .date: return "calendar"
        case .checkbox: return "checkmark.square"
        case .url: return "link"
        case .singleSelect: return "circle.circle"
        case .multiSelect: return "checklist"
        }
    }

    /// Whether this kind stores `optionIds` and requires an `options` list on the definition.
    var usesOptions: Bool {
        self == .singleSelect || self == .multiSelect
    }

    /// Default table column width (pts) for cells of this kind.
    var defaultColumnWidth: CGFloat {
        switch self {
        case .text, .url: return 180
        case .longText: return 220
        case .number: return 100
        case .date: return 130
        case .checkbox: return 80
        case .singleSelect: return 150
        case .multiSelect: return 200
        }
    }
}

// MARK: - Custom Field Option (for select kinds)

struct CustomFieldOption: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    /// Hex like "#FF7043". Optional — UI falls back to a default chip color.
    var colorHex: String?

    init(id: UUID = UUID(), label: String, colorHex: String? = nil) {
        self.id = id
        self.label = label
        self.colorHex = colorHex
    }
}

// Convenience palette so the editor can offer a small set of chip colors.
enum CustomFieldOptionPalette {
    static let hexes: [String] = [
        "#EF5350", "#FF7043", "#FFCA28", "#66BB6A",
        "#26C6DA", "#42A5F5", "#7E57C2", "#EC407A"
    ]
}

// MARK: - Custom Field Definition

struct CustomFieldDefinition: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: CustomFieldKind
    var options: [CustomFieldOption]
    var sortIndex: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: CustomFieldKind,
        options: [CustomFieldOption] = [],
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.options = options
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(CustomFieldKind.self, forKey: .kind)
        options = (try? container.decode([CustomFieldOption].self, forKey: .options)) ?? []
        sortIndex = (try? container.decode(Int.self, forKey: .sortIndex)) ?? 0
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - Custom Field Value

/// Typed value stored per-connection, keyed by `CustomFieldDefinition.id`.
/// Tagged-enum encoding keeps the JSON compact and round-trips cleanly.
enum CustomFieldValue: Codable, Equatable, Hashable {
    case text(String)
    case number(Double)
    case date(Date)
    case bool(Bool)
    case url(String)
    case optionIds([UUID])

    private enum Kind: String, Codable {
        case text, number, date, bool, url, optionIds
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(s, forKey: .value)
        case .number(let n):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(n, forKey: .value)
        case .date(let d):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(d, forKey: .value)
        case .bool(let b):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(b, forKey: .value)
        case .url(let s):
            try container.encode(Kind.url, forKey: .kind)
            try container.encode(s, forKey: .value)
        case .optionIds(let ids):
            try container.encode(Kind.optionIds, forKey: .kind)
            try container.encode(ids, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:      self = .text(try container.decode(String.self, forKey: .value))
        case .number:    self = .number(try container.decode(Double.self, forKey: .value))
        case .date:      self = .date(try container.decode(Date.self, forKey: .value))
        case .bool:      self = .bool(try container.decode(Bool.self, forKey: .value))
        case .url:       self = .url(try container.decode(String.self, forKey: .value))
        case .optionIds: self = .optionIds(try container.decode([UUID].self, forKey: .value))
        }
    }

    /// True when the value carries no meaningful content (used by the
    /// inline editor to decide whether to delete the dict entry on save).
    var isEmpty: Bool {
        switch self {
        case .text(let s), .url(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .number: return false
        case .date: return false
        case .bool(let b): return !b
        case .optionIds(let ids): return ids.isEmpty
        }
    }
}

// MARK: - Color helper for option chips

extension Color {
    /// Create a Color from a "#RRGGBB" hex string. Returns nil on parse failure.
    static func fromHex(_ hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >>  8) & 0xFF) / 255.0
        let b = Double( v        & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
