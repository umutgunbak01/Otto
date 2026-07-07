import Foundation
import SwiftUI

// MARK: - Company Type

enum CompanyType: String, CaseIterable, Codable, Identifiable {
    case unknown = "unknown"
    case startup = "startup"
    case scaleup = "scaleup"
    case enterprise = "enterprise"
    case vc = "vc"
    case agency = "agency"
    case research = "research"
    case media = "media"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "Uncategorized"
        case .startup: return "Startup"
        case .scaleup: return "Scale-up"
        case .enterprise: return "Enterprise"
        case .vc: return "VC / Fund"
        case .agency: return "Agency"
        case .research: return "Research / Lab"
        case .media: return "Media"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .startup: return "bolt.fill"
        case .scaleup: return "chart.line.uptrend.xyaxis"
        case .enterprise: return "building.2.fill"
        case .vc: return "dollarsign.circle.fill"
        case .agency: return "paintbrush.fill"
        case .research: return "flask.fill"
        case .media: return "newspaper.fill"
        case .other: return "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Theme.Colors.tertiaryText
        case .startup: return Theme.Colors.cyan
        case .scaleup: return Theme.Colors.green
        case .enterprise: return Theme.Colors.cyanDim
        case .vc: return Theme.Colors.green
        case .agency: return Theme.Colors.amber
        case .research: return Theme.Colors.cyanDim
        case .media: return Theme.Colors.red
        case .other: return Theme.Colors.textDim
        }
    }
}

// MARK: - Company

struct Company: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: CompanyType
    var location: String              // Free-text city/region; drives map placement
    var isCustomer: Bool
    var commitmentAmount: Double?     // $ committed (revenue / deal size)
    var website: String?
    var notes: String
    var tags: [String]
    var linkedConnectionIds: [UUID]    // Linked LinkedIn connections
    var linkedNetworkEntryIds: [UUID]  // Linked Network Hub people (shown on the detail page)
    let createdAt: Date
    var updatedAt: Date

    // MARK: - Computed

    var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "—" }
        let words = trimmed.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].first.map(String.init) ?? "")\(words[1].first.map(String.init) ?? "")".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Compact money label, e.g. "$50K", "$1.2M". Returns nil when no amount set.
    var formattedCommitment: String? {
        guard let amount = commitmentAmount, amount > 0 else { return nil }
        return Self.formatMoney(amount)
    }

    static func formatMoney(_ amount: Double) -> String {
        let sign = amount < 0 ? "-" : ""
        let value = abs(amount)
        switch value {
        case 1_000_000...:
            let m = value / 1_000_000
            return "\(sign)$\(trimZeros(m))M"
        case 1_000...:
            let k = value / 1_000
            return "\(sign)$\(trimZeros(k))K"
        default:
            return "\(sign)$\(trimZeros(value))"
        }
    }

    private static func trimZeros(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    var searchableContent: String {
        [name, type.label, location, notes, tags.joined(separator: " "), website ?? ""]
            .joined(separator: " ")
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        type: CompanyType = .unknown,
        location: String = "",
        isCustomer: Bool = false,
        commitmentAmount: Double? = nil,
        website: String? = nil,
        notes: String = "",
        tags: [String] = [],
        linkedConnectionIds: [UUID] = [],
        linkedNetworkEntryIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.location = location
        self.isCustomer = isCustomer
        self.commitmentAmount = commitmentAmount
        self.website = website
        self.notes = notes
        self.tags = tags
        self.linkedConnectionIds = linkedConnectionIds
        self.linkedNetworkEntryIds = linkedNetworkEntryIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable (lenient — new optional fields tolerate older stores)

extension Company {
    enum CodingKeys: String, CodingKey {
        case id, name, type, location, isCustomer, commitmentAmount
        case website, notes, tags, linkedConnectionIds, linkedNetworkEntryIds, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = (try? container.decode(CompanyType.self, forKey: .type)) ?? .unknown
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        isCustomer = (try? container.decode(Bool.self, forKey: .isCustomer)) ?? false
        commitmentAmount = try? container.decode(Double.self, forKey: .commitmentAmount)
        website = try? container.decode(String.self, forKey: .website)
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        linkedConnectionIds = (try? container.decode([UUID].self, forKey: .linkedConnectionIds)) ?? []
        linkedNetworkEntryIds = (try? container.decode([UUID].self, forKey: .linkedNetworkEntryIds)) ?? []
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}
