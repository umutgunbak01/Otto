import Foundation
import SwiftUI

// MARK: - Event Type

enum EventType: String, CaseIterable, Codable, Identifiable {
    case unknown = "unknown"
    case conference = "conference"
    case summit = "summit"
    case meetup = "meetup"
    case hackathon = "hackathon"
    case dinner = "dinner"
    case workshop = "workshop"
    case party = "party"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "Uncategorized"
        case .conference: return "Conference"
        case .summit: return "Summit"
        case .meetup: return "Meetup"
        case .hackathon: return "Hackathon"
        case .dinner: return "Dinner"
        case .workshop: return "Workshop"
        case .party: return "Party"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .conference: return "person.3.fill"
        case .summit: return "mountain.2.fill"
        case .meetup: return "person.2.fill"
        case .hackathon: return "laptopcomputer"
        case .dinner: return "fork.knife"
        case .workshop: return "hammer.fill"
        case .party: return "party.popper.fill"
        case .other: return "calendar"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Theme.Colors.tertiaryText
        case .conference: return Theme.Colors.cyan
        case .summit: return Theme.Colors.cyanDim
        case .meetup: return Theme.Colors.green
        case .hackathon: return Theme.Colors.aiAccent
        case .dinner: return Theme.Colors.amber
        case .workshop: return Theme.Colors.cyanDim
        case .party: return Theme.Colors.red
        case .other: return Theme.Colors.textDim
        }
    }
}

// MARK: - Event Status (your relationship to the event)

enum EventStatus: String, CaseIterable, Codable, Identifiable {
    case considering = "considering"
    case attending = "attending"
    case hosting = "hosting"
    case declined = "declined"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .considering: return "Considering"
        case .attending: return "Attending"
        case .hosting: return "Hosting"
        case .declined: return "Declined"
        }
    }

    var icon: String {
        switch self {
        case .considering: return "questionmark.circle"
        case .attending: return "checkmark.circle.fill"
        case .hosting: return "star.circle.fill"
        case .declined: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .considering: return Theme.Colors.amber
        case .attending: return Theme.Colors.green
        case .hosting: return Theme.Colors.cyan
        case .declined: return Theme.Colors.textDim
        }
    }
}

// MARK: - Event

struct Event: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: EventType
    var location: String              // Free-text city/region; drives map placement
    var startDate: Date?
    var endDate: Date?
    var status: EventStatus
    var budgetAmount: Double?         // $ budget / sponsorship
    var notes: String
    var tags: [String]
    var linkedConnectionIds: [UUID]   // People you know going / want to meet there
    let createdAt: Date
    var updatedAt: Date

    // MARK: - Computed

    /// Human date label, e.g. "Mar 3", "Mar 3 – 5", "Mar 30 – Apr 2". Empty when undated.
    var dateRangeText: String {
        guard let start = startDate else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        guard let end = endDate, end != start else {
            return df.string(from: start)
        }
        let cal = Calendar.current
        if cal.isDate(start, equalTo: end, toGranularity: .month) {
            let dayOnly = DateFormatter()
            dayOnly.dateFormat = "d"
            return "\(df.string(from: start)) – \(dayOnly.string(from: end))"
        }
        return "\(df.string(from: start)) – \(df.string(from: end))"
    }

    /// True when the event hasn't ended yet (upcoming or ongoing).
    var isUpcoming: Bool {
        let ref = endDate ?? startDate
        guard let ref else { return true } // undated events sort as upcoming
        return ref >= Calendar.current.startOfDay(for: Date())
    }

    var formattedBudget: String? {
        guard let amount = budgetAmount, amount > 0 else { return nil }
        return Company.formatMoney(amount)
    }

    var searchableContent: String {
        [name, type.label, location, status.label, notes, tags.joined(separator: " ")]
            .joined(separator: " ")
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        type: EventType = .unknown,
        location: String = "",
        startDate: Date? = nil,
        endDate: Date? = nil,
        status: EventStatus = .considering,
        budgetAmount: Double? = nil,
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
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.budgetAmount = budgetAmount
        self.notes = notes
        self.tags = tags
        self.linkedConnectionIds = linkedConnectionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable (lenient)

extension Event {
    enum CodingKeys: String, CodingKey {
        case id, name, type, location, startDate, endDate, status
        case budgetAmount, notes, tags, linkedConnectionIds, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = (try? container.decode(EventType.self, forKey: .type)) ?? .unknown
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        startDate = try? container.decode(Date.self, forKey: .startDate)
        endDate = try? container.decode(Date.self, forKey: .endDate)
        status = (try? container.decode(EventStatus.self, forKey: .status)) ?? .considering
        budgetAmount = try? container.decode(Double.self, forKey: .budgetAmount)
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        linkedConnectionIds = (try? container.decode([UUID].self, forKey: .linkedConnectionIds)) ?? []
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}
