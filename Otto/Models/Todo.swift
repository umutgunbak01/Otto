import SwiftUI

struct Todo: Identifiable, Codable {
    let id: UUID
    var title: String
    var description: String
    var dueDate: Date?
    var priority: Priority
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var todoistId: String?
    var todoistProjectName: String?
    var domainTagIds: [UUID]
    var subTasks: [SubTask]

    // MARK: - SubTask

    struct SubTask: Identifiable, Codable, Equatable {
        let id: UUID
        var title: String
        var isCompleted: Bool
        var createdAt: Date

        init(
            id: UUID = UUID(),
            title: String,
            isCompleted: Bool = false,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.isCompleted = isCompleted
            self.createdAt = createdAt
        }

        mutating func toggleCompletion() {
            isCompleted.toggle()
        }
    }

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case id, title, description, dueDate, priority
        case isCompleted, completedAt, createdAt, updatedAt
        case todoistId, todoistProjectName
        case domainTagIds, subTasks
    }

    enum Priority: Int, Codable, CaseIterable, Comparable, Identifiable {
        case low = 1
        case medium = 2
        case high = 3
        case urgent = 4

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .urgent: return "Urgent"
            }
        }

        var color: Color {
            switch self {
            case .low: return .gray
            case .medium: return .blue
            case .high: return .orange
            case .urgent: return .red
            }
        }

        var iconName: String {
            switch self {
            case .low: return "flag"
            case .medium: return "flag.fill"
            case .high: return "exclamationmark.triangle"
            case .urgent: return "exclamationmark.triangle.fill"
            }
        }

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        dueDate: Date? = nil,
        priority: Priority = .medium,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        todoistId: String? = nil,
        todoistProjectName: String? = nil,
        domainTagIds: [UUID] = [],
        subTasks: [SubTask] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.priority = priority
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.todoistId = todoistId
        self.todoistProjectName = todoistProjectName
        self.domainTagIds = domainTagIds
        self.subTasks = subTasks
    }

    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        priority = try container.decode(Priority.self, forKey: .priority)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        todoistId = try container.decodeIfPresent(String.self, forKey: .todoistId)
        todoistProjectName = try container.decodeIfPresent(String.self, forKey: .todoistProjectName)

        // New fields with backward-compatible fallbacks
        domainTagIds = (try? container.decode([UUID].self, forKey: .domainTagIds)) ?? []
        subTasks = (try? container.decode([SubTask].self, forKey: .subTasks)) ?? []
    }

    mutating func toggleCompletion() {
        isCompleted.toggle()
        completedAt = isCompleted ? Date() : nil
        updatedAt = Date()
    }
}
