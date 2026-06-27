import Foundation
import SwiftUI

// MARK: - Community Type

enum CommunityType: String, CaseIterable, Codable, Identifiable {
    case community = "community"
    case society = "society"
    case collective = "collective"
    case accelerator = "accelerator"
    case dao = "dao"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .community: return "Community"
        case .society: return "Society"
        case .collective: return "Collective"
        case .accelerator: return "Accelerator"
        case .dao: return "DAO"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .community: return "person.3.fill"
        case .society: return "graduationcap.fill"
        case .collective: return "circle.hexagongrid.fill"
        case .accelerator: return "bolt.fill"
        case .dao: return "cube.transparent"
        case .other: return "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .community: return Theme.Colors.green
        case .society: return .purple
        case .collective: return .teal
        case .accelerator: return Theme.Colors.amber
        case .dao: return .indigo
        case .other: return .gray
        }
    }
}

// MARK: - Community

struct Community: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: CommunityType
    var location: String              // Free-text city/region; drives map placement
    var builderSupportPerk: Bool      // Offers a perk for builders?
    var url: String?
    var notes: String
    var tags: [String]
    var linkedConnectionIds: [UUID]
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

    var searchableContent: String {
        [name, type.label, location, notes, tags.joined(separator: " "), url ?? ""]
            .joined(separator: " ")
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        type: CommunityType = .community,
        location: String = "",
        builderSupportPerk: Bool = false,
        url: String? = nil,
        notes: String = "",
        tags: [String] = [],
        linkedConnectionIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.location = location
        self.builderSupportPerk = builderSupportPerk
        self.url = url
        self.notes = notes
        self.tags = tags
        self.linkedConnectionIds = linkedConnectionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable (lenient)

extension Community {
    enum CodingKeys: String, CodingKey {
        case id, name, type, location, builderSupportPerk
        case url, notes, tags, linkedConnectionIds, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = (try? container.decode(CommunityType.self, forKey: .type)) ?? .community
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        builderSupportPerk = (try? container.decode(Bool.self, forKey: .builderSupportPerk)) ?? false
        url = try? container.decode(String.self, forKey: .url)
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        linkedConnectionIds = (try? container.decode([UUID].self, forKey: .linkedConnectionIds)) ?? []
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}
