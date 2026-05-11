import Foundation

struct Reminder: Identifiable, Codable {
    let id: UUID
    var title: String
    var reminderDate: Date
    var isTriggered: Bool
    var isCompleted: Bool
    var completedAt: Date?
    var notificationId: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        reminderDate: Date,
        isTriggered: Bool = false,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        notificationId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.reminderDate = reminderDate
        self.isTriggered = isTriggered
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.notificationId = notificationId
        self.createdAt = createdAt
    }

    // Custom decoder to handle backward compatibility with old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        reminderDate = try container.decode(Date.self, forKey: .reminderDate)
        isTriggered = try container.decodeIfPresent(Bool.self, forKey: .isTriggered) ?? false
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        notificationId = try container.decodeIfPresent(String.self, forKey: .notificationId)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, reminderDate, isTriggered, isCompleted, completedAt, notificationId, createdAt
    }

    var isPast: Bool {
        reminderDate < Date()
    }

    var isUpcoming: Bool {
        !isPast && !isTriggered
    }

    var isPastDue: Bool {
        isPast && !isCompleted
    }

    mutating func markCompleted() {
        isCompleted = true
        completedAt = Date()
    }
}
