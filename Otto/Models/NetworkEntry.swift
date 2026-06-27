import Foundation
import SwiftUI

// MARK: - Network Type (organization classification — the "Type" column)

enum NetworkType: String, CaseIterable, Codable {
    case startup = "Startup"
    case investor = "Investor"
    case appStudio = "App Studio"
    case enterprise = "Enterprise"
    case media = "Media"
    case community = "Community"
    case incubator = "Incubator"
    case accelerator = "Accelerator"
    case consulting = "Consulting"
    case ecosystem = "Ecosystem"
    case other = "Other"

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .startup:     return "sparkles"
        case .investor:    return "dollarsign.circle.fill"
        case .appStudio:   return "square.stack.3d.up.fill"
        case .enterprise:  return "building.2.fill"
        case .media:       return "antenna.radiowaves.left.and.right"
        case .community:   return "person.3.fill"
        case .incubator:   return "leaf.fill"
        case .accelerator: return "bolt.fill"
        case .consulting:  return "briefcase.fill"
        case .ecosystem:   return "globe"
        case .other:       return "circle.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .startup:     return .green
        case .investor:    return .yellow
        case .appStudio:   return .purple
        case .enterprise:  return .blue
        case .media:       return .pink
        case .community:   return .orange
        case .incubator:   return .teal
        case .accelerator: return .mint
        case .consulting:  return .brown
        case .ecosystem:   return .indigo
        case .other:       return .gray
        }
    }
}

// MARK: - Individual Type (the "Individual Type" column)

enum IndividualType: String, CaseIterable, Codable {
    case founder = "Founder"
    case vc = "VC"
    case operatorRole = "Operator"
    case engineer = "Engineer"
    case communityBuilder = "Community Builder"
    case angelInvestor = "Angel Investor"
    case creative = "Creative"
    case other = "Other"

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .founder:          return "flag.fill"
        case .vc:               return "dollarsign.circle.fill"
        case .operatorRole:     return "gearshape.fill"
        case .engineer:         return "hammer.fill"
        case .communityBuilder: return "person.3.fill"
        case .angelInvestor:    return "sparkle"
        case .creative:         return "paintbrush.fill"
        case .other:            return "person.fill"
        }
    }

    var color: Color {
        switch self {
        case .founder:          return .purple
        case .vc:               return .green
        case .operatorRole:     return .blue
        case .engineer:         return .cyan
        case .communityBuilder: return .orange
        case .angelInvestor:    return .yellow
        case .creative:         return .pink
        case .other:            return .gray
        }
    }
}

// MARK: - Network Closeness (the "Closeness" column)

enum NetworkCloseness: String, CaseIterable, Codable {
    case closeFriend = "Close friend"
    case warmRelationship = "Warm relationship"
    case knownPersonally = "Known personally"
    case introPath = "Intro path available"
    case lightConnection = "Light connection"
    case unknown = "Unknown"

    var label: String { rawValue }

    /// Higher = stronger tie. Used when sorting by relationship strength.
    var rank: Int {
        switch self {
        case .closeFriend:      return 5
        case .warmRelationship: return 4
        case .knownPersonally:  return 3
        case .introPath:        return 2
        case .lightConnection:  return 1
        case .unknown:          return 0
        }
    }

    var icon: String {
        switch self {
        case .closeFriend:      return "heart.circle.fill"
        case .warmRelationship: return "flame.fill"
        case .knownPersonally:  return "person.fill.checkmark"
        case .introPath:        return "arrow.triangle.branch"
        case .lightConnection:  return "person.crop.circle"
        case .unknown:          return "person.crop.circle.badge.questionmark"
        }
    }

    var color: Color {
        switch self {
        case .closeFriend:      return .pink
        case .warmRelationship: return .orange
        case .knownPersonally:  return .green
        case .introPath:        return .blue
        case .lightConnection:  return .gray
        case .unknown:          return .gray
        }
    }
}

// MARK: - LinkedIn Profile (structured, imported from a LinkedIn PDF export)

struct LinkedInExperience: Codable, Equatable {
    var company: String = ""
    var title: String = ""
    var dateRange: String = ""
    var location: String = ""
    var description: String = ""

    init(company: String = "", title: String = "", dateRange: String = "",
         location: String = "", description: String = "") {
        self.company = company; self.title = title; self.dateRange = dateRange
        self.location = location; self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = (try? c.decode(String.self, forKey: .company)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        dateRange = (try? c.decode(String.self, forKey: .dateRange)) ?? ""
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
    }
}

struct LinkedInEducation: Codable, Equatable {
    var school: String = ""
    var detail: String = ""

    init(school: String = "", detail: String = "") {
        self.school = school; self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        school = (try? c.decode(String.self, forKey: .school)) ?? ""
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
    }
}

/// Structured LinkedIn data attached to a network entry. Populated by importing
/// LinkedIn "Save to PDF" exports — surfaced as sections in the detail view
/// rather than dumped into free-text notes.
struct LinkedInProfile: Codable, Equatable {
    var headline: String = ""
    var location: String = ""
    var summary: String = ""
    var skills: [String] = []
    var languages: [String] = []
    var certifications: [String] = []
    var experiences: [LinkedInExperience] = []
    var education: [LinkedInEducation] = []
    var email: String = ""
    var profileUrl: String = ""

    var isEmpty: Bool {
        summary.isEmpty && experiences.isEmpty && education.isEmpty
            && skills.isEmpty && languages.isEmpty && certifications.isEmpty
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        skills = (try? c.decode([String].self, forKey: .skills)) ?? []
        languages = (try? c.decode([String].self, forKey: .languages)) ?? []
        certifications = (try? c.decode([String].self, forKey: .certifications)) ?? []
        experiences = (try? c.decode([LinkedInExperience].self, forKey: .experiences)) ?? []
        education = (try? c.decode([LinkedInEducation].self, forKey: .education)) ?? []
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        profileUrl = (try? c.decode(String.self, forKey: .profileUrl)) ?? ""
    }
}

// MARK: - Network Entry

/// A single row in the strategic Network Hub — a person (or organization)
/// classified by org type, industry, role, and relationship strength. Mirrors
/// the columns of the imported "Network" spreadsheet. Distinct from `Connection`
/// (the raw LinkedIn CSV import).
struct NetworkEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var type: NetworkType
    var company: String
    var industry: String
    var name: String
    var individualType: IndividualType
    var title: String
    var location: String
    var email: String
    var linkedin: String?
    var closeness: NetworkCloseness
    var notes: String
    /// Structured LinkedIn data, when imported from a PDF export.
    var profile: LinkedInProfile?
    let createdAt: Date
    var updatedAt: Date

    // MARK: - Computed Properties

    var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
        let joined = parts.joined().uppercased()
        return joined.isEmpty ? "•" : joined
    }

    /// Headline shown under the name — e.g. "General Partner @ e2vc".
    var displayInfo: String {
        [title, company].filter { !$0.isEmpty }.joined(separator: " @ ")
    }

    var searchableContent: String {
        var parts: [String] = [
            name, company, industry, title, location, email, notes,
            type.label, individualType.label, closeness.label,
            linkedin ?? ""
        ]
        if let p = profile {
            parts.append(contentsOf: [p.headline, p.location, p.summary, p.email])
            parts.append(p.skills.joined(separator: " "))
            parts.append(p.languages.joined(separator: " "))
            parts.append(p.certifications.joined(separator: " "))
            for e in p.experiences {
                parts.append(contentsOf: [e.company, e.title, e.dateRange, e.location, e.description])
            }
            for ed in p.education {
                parts.append(contentsOf: [ed.school, ed.detail])
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        type: NetworkType = .other,
        company: String = "",
        industry: String = "",
        name: String = "",
        individualType: IndividualType = .other,
        title: String = "",
        location: String = "",
        email: String = "",
        linkedin: String? = nil,
        closeness: NetworkCloseness = .unknown,
        notes: String = "",
        profile: LinkedInProfile? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.company = company
        self.industry = industry
        self.name = name
        self.individualType = individualType
        self.title = title
        self.location = location
        self.email = email
        self.linkedin = linkedin
        self.closeness = closeness
        self.notes = notes
        self.profile = profile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable

extension NetworkEntry {
    enum CodingKeys: String, CodingKey {
        case id, type, company, industry, name, individualType, title
        case location, email
        case linkedin, closeness, notes, profile, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        // Enum columns fall back to a catch-all so an unexpected string in the
        // source data never fails the whole decode.
        type = (try? container.decode(NetworkType.self, forKey: .type)) ?? .other
        company = (try? container.decode(String.self, forKey: .company)) ?? ""
        industry = (try? container.decode(String.self, forKey: .industry)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        individualType = (try? container.decode(IndividualType.self, forKey: .individualType)) ?? .other
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        linkedin = try? container.decode(String.self, forKey: .linkedin)
        closeness = (try? container.decode(NetworkCloseness.self, forKey: .closeness)) ?? .unknown
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        profile = try? container.decode(LinkedInProfile.self, forKey: .profile)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(company, forKey: .company)
        try container.encode(industry, forKey: .industry)
        try container.encode(name, forKey: .name)
        try container.encode(individualType, forKey: .individualType)
        try container.encode(title, forKey: .title)
        try container.encode(location, forKey: .location)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(linkedin, forKey: .linkedin)
        try container.encode(closeness, forKey: .closeness)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
