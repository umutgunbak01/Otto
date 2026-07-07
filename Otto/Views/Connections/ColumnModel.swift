import Foundation
import SwiftUI

// MARK: - Column identity

enum BuiltInColumn: String, Codable, CaseIterable, Hashable {
    case headline       // current title
    case company        // current company
    case email
    case phone
    case location
    case education
    case birthday
    case connectionDate
    case lastContactedAt
    case closeness
    case category
    case tags
    case notes

    var label: String {
        switch self {
        case .headline:        return "Title"
        case .company:         return "Company"
        case .email:           return "Email"
        case .phone:           return "Phone"
        case .location:        return "Location"
        case .education:       return "Education"
        case .birthday:        return "Birthday"
        case .connectionDate:  return "Connected on"
        case .lastContactedAt: return "Last contact"
        case .closeness:       return "Closeness"
        case .category:        return "Category"
        case .tags:            return "Tags"
        case .notes:           return "Notes"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .headline:        return 200
        case .company:         return 180
        case .email:           return 220
        case .phone:           return 140
        case .location:        return 160
        case .education:       return 200
        case .birthday:        return 130
        case .connectionDate:  return 130
        case .lastContactedAt: return 140
        case .closeness:       return 150
        case .category:        return 150
        case .tags:            return 220
        case .notes:           return 240
        }
    }
}

/// A column in the Connections table. The Name column is pinned-left and
/// implicit — it's not part of `ColumnLayout.visible`.
enum ConnectionColumn: Hashable, Codable {
    case builtIn(BuiltInColumn)
    case custom(UUID)

    /// Stable string id for use as a dict key (width persistence).
    var storageKey: String {
        switch self {
        case .builtIn(let b): return "builtin:\(b.rawValue)"
        case .custom(let id): return "custom:\(id.uuidString)"
        }
    }
}

// MARK: - Column layout (per-device, persisted via ConnectionColumnLayoutStore)

struct ColumnLayout: Codable, Equatable {
    /// Display order, left to right. Name column is always pinned-left and
    /// not represented here.
    var visible: [ConnectionColumn]
    /// User-overridden widths, keyed by `ConnectionColumn.storageKey`.
    /// Missing keys fall back to the column's default width.
    var widths: [String: CGFloat]

    static let `default` = ColumnLayout(
        visible: [
            .builtIn(.headline),
            .builtIn(.company),
            .builtIn(.email),
            .builtIn(.phone),
            .builtIn(.birthday),
            .builtIn(.education),
            .builtIn(.closeness),
            .builtIn(.category),
            .builtIn(.lastContactedAt),
        ],
        widths: [:]
    )

    /// Effective width for a column, clamped to a sane range.
    func width(for column: ConnectionColumn, definitions: [CustomFieldDefinition]) -> CGFloat {
        if let stored = widths[column.storageKey] {
            return min(max(stored, 80), 600)
        }
        return defaultWidth(for: column, definitions: definitions)
    }

    func defaultWidth(for column: ConnectionColumn, definitions: [CustomFieldDefinition]) -> CGFloat {
        switch column {
        case .builtIn(let b): return b.defaultWidth
        case .custom(let id):
            let kind = definitions.first(where: { $0.id == id })?.kind ?? .text
            return kind.defaultColumnWidth
        }
    }

    /// Returns every available column (built-in + currently-defined custom),
    /// in the order they should appear in the Columns menu: visible-first
    /// in their current order, then hidden ones grouped by built-in / custom.
    static func availableColumns(definitions: [CustomFieldDefinition]) -> [ConnectionColumn] {
        var result: [ConnectionColumn] = BuiltInColumn.allCases.map { .builtIn($0) }
        result.append(contentsOf: definitions.sorted { $0.sortIndex < $1.sortIndex }.map { .custom($0.id) })
        return result
    }

    /// Display label for a column.
    static func label(for column: ConnectionColumn, definitions: [CustomFieldDefinition]) -> String {
        switch column {
        case .builtIn(let b): return b.label
        case .custom(let id): return definitions.first(where: { $0.id == id })?.name ?? "Custom"
        }
    }

    /// SF Symbol shown next to the column name in menus.
    static func icon(for column: ConnectionColumn, definitions: [CustomFieldDefinition]) -> String {
        switch column {
        case .builtIn(let b):
            switch b {
            case .headline: return "briefcase"
            case .company: return "building.2"
            case .email: return "envelope"
            case .phone: return "phone"
            case .location: return "mappin"
            case .education: return "graduationcap"
            case .birthday: return "gift"
            case .connectionDate: return "calendar.badge.plus"
            case .lastContactedAt: return "clock.arrow.circlepath"
            case .closeness: return "heart.circle"
            case .category: return "square.grid.2x2"
            case .tags: return "tag"
            case .notes: return "note.text"
            }
        case .custom(let id):
            let kind = definitions.first(where: { $0.id == id })?.kind ?? .text
            return kind.icon
        }
    }
}

// MARK: - Custom field codable hint for ConnectionColumn

extension ConnectionColumn {
    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String, Codable {
        case builtIn, custom
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let b):
            try c.encode(Kind.builtIn, forKey: .kind)
            try c.encode(b.rawValue, forKey: .value)
        case .custom(let id):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(id, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .builtIn:
            let raw = try c.decode(String.self, forKey: .value)
            guard let b = BuiltInColumn(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Unknown built-in column \(raw)")
            }
            self = .builtIn(b)
        case .custom:
            let id = try c.decode(UUID.self, forKey: .value)
            self = .custom(id)
        }
    }
}

// MARK: - Date helpers (used by Last contact, Birthday, Connected on cells)

enum ConnectionDateFormat {
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
