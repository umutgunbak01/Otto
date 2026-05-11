import Foundation
import SwiftUI

// MARK: - Connection Closeness

enum ConnectionCloseness: String, CaseIterable, Codable {
    case unknown = "unknown"
    case acquaintance = "acquaintance"
    case friendly = "friendly"
    case close = "close"

    var label: String {
        switch self {
        case .unknown: return "Haven't Met"
        case .acquaintance: return "Acquaintance"
        case .friendly: return "Get Along Well"
        case .close: return "Close Friend"
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "person.crop.circle.badge.questionmark"
        case .acquaintance: return "person.crop.circle"
        case .friendly: return "person.2.fill"
        case .close: return "heart.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .acquaintance: return .blue
        case .friendly: return .orange
        case .close: return .pink
        }
    }
}

// MARK: - Connection Category

enum ConnectionCategory: String, CaseIterable, Codable {
    case unknown = "unknown"
    case investor = "investor"
    case founder = "founder"
    case engineer = "engineer"
    case ecosystem = "ecosystem"
    case friend = "friend"
    case family = "family"
    case other = "other"

    var label: String {
        switch self {
        case .unknown: return "Uncategorized"
        case .investor: return "Investor"
        case .founder: return "Founder"
        case .engineer: return "Engineer"
        case .ecosystem: return "Ecosystem"
        case .friend: return "Friend"
        case .family: return "Family"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .investor: return "dollarsign.circle.fill"
        case .founder: return "building.2.fill"
        case .engineer: return "hammer.fill"
        case .ecosystem: return "leaf.fill"
        case .friend: return "person.2.fill"
        case .family: return "house.fill"
        case .other: return "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .investor: return .green
        case .founder: return .purple
        case .engineer: return .blue
        case .ecosystem: return .teal
        case .friend: return .orange
        case .family: return .pink
        case .other: return .indigo
        }
    }
}

// MARK: - Connection

struct Connection: Identifiable, Codable, Equatable {
    let id: UUID
    var firstName: String
    var lastName: String
    var headline: String              // Job title/position
    var company: String
    var location: String
    var email: String?
    var profileUrl: String?
    var connectionDate: Date?
    var notes: String                 // User-editable notes
    var tags: [String]                // User-defined tags for categorization
    var closeness: ConnectionCloseness
    var category: ConnectionCategory
    var linkedXFollowerId: UUID?
    let importedAt: Date
    var updatedAt: Date

    // MARK: - Computed Properties

    var fullName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }

    var initials: String {
        let first = firstName.first.map { String($0).uppercased() } ?? ""
        let last = lastName.first.map { String($0).uppercased() } ?? ""
        return "\(first)\(last)"
    }

    var displayInfo: String {
        [headline, company].filter { !$0.isEmpty }.joined(separator: " at ")
    }

    var formattedConnectionDate: String {
        guard let date = connectionDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String,
        headline: String = "",
        company: String = "",
        location: String = "",
        email: String? = nil,
        profileUrl: String? = nil,
        connectionDate: Date? = nil,
        notes: String = "",
        tags: [String] = [],
        closeness: ConnectionCloseness = .unknown,
        category: ConnectionCategory = .unknown,
        linkedXFollowerId: UUID? = nil,
        importedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.headline = headline
        self.company = company
        self.location = location
        self.email = email
        self.profileUrl = profileUrl
        self.connectionDate = connectionDate
        self.notes = notes
        self.tags = tags
        self.closeness = closeness
        self.category = category
        self.linkedXFollowerId = linkedXFollowerId
        self.importedAt = importedAt
        self.updatedAt = updatedAt
    }

    // MARK: - Search Helpers

    /// Returns all searchable text for this connection
    var searchableContent: String {
        [
            fullName,
            headline,
            company,
            location,
            notes,
            tags.joined(separator: " "),
            email ?? ""
        ].joined(separator: " ")
    }
}

// MARK: - Codable

extension Connection {
    enum CodingKeys: String, CodingKey {
        case id, firstName, lastName, headline, company, location
        case email, profileUrl, connectionDate, notes, tags, closeness, category
        case linkedXFollowerId, importedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        headline = (try? container.decode(String.self, forKey: .headline)) ?? ""
        company = (try? container.decode(String.self, forKey: .company)) ?? ""
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        email = try? container.decode(String.self, forKey: .email)
        profileUrl = try? container.decode(String.self, forKey: .profileUrl)
        connectionDate = try? container.decode(Date.self, forKey: .connectionDate)
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        closeness = (try? container.decode(ConnectionCloseness.self, forKey: .closeness)) ?? .unknown
        category = (try? container.decode(ConnectionCategory.self, forKey: .category)) ?? .unknown
        linkedXFollowerId = try? container.decode(UUID.self, forKey: .linkedXFollowerId)
        importedAt = (try? container.decode(Date.self, forKey: .importedAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}
