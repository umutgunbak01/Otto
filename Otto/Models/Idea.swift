import Foundation

struct Idea: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var primaryCategory: PrimaryCategory
    var domainTagIds: [UUID]
    var status: Status
    var researchPrompt: String
    var validationPrompt: String
    var mindMapImageData: Data?
    var createdAt: Date
    var updatedAt: Date

    enum Status: String, Codable, CaseIterable, Identifiable {
        case raw = "Raw"
        case researched = "Researched"
        case validated = "Validated"
        case archived = "Archived"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .raw: return "sparkle"
            case .researched: return "magnifyingglass"
            case .validated: return "checkmark.seal"
            case .archived: return "archivebox"
            }
        }
    }

    // Custom CodingKeys to support both old and new field names
    enum CodingKeys: String, CodingKey {
        case id, title, content, primaryCategory, domainTagIds, status
        case researchPrompt, validationPrompt, mindMapImageData
        case researchNotes, validationNotes // Old field names for migration
        case createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        primaryCategory: PrimaryCategory = .personal,
        domainTagIds: [UUID] = [],
        status: Status = .raw,
        researchPrompt: String = "",
        validationPrompt: String = "",
        mindMapImageData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.primaryCategory = primaryCategory
        self.domainTagIds = domainTagIds
        self.status = status
        self.researchPrompt = researchPrompt
        self.validationPrompt = validationPrompt
        self.mindMapImageData = mindMapImageData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoder to handle migration from old field names
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        primaryCategory = try container.decode(PrimaryCategory.self, forKey: .primaryCategory)
        domainTagIds = try container.decode([UUID].self, forKey: .domainTagIds)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Try new field names first, fall back to old field names for migration
        if let prompt = try? container.decode(String.self, forKey: .researchPrompt) {
            researchPrompt = prompt
        } else if let notes = try? container.decode(String.self, forKey: .researchNotes) {
            researchPrompt = notes
        } else {
            researchPrompt = ""
        }

        if let prompt = try? container.decode(String.self, forKey: .validationPrompt) {
            validationPrompt = prompt
        } else if let notes = try? container.decode(String.self, forKey: .validationNotes) {
            validationPrompt = notes
        } else {
            validationPrompt = ""
        }

        // Mind map is optional
        mindMapImageData = try? container.decode(Data.self, forKey: .mindMapImageData)
    }

    // Custom encoder to use new field names
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(primaryCategory, forKey: .primaryCategory)
        try container.encode(domainTagIds, forKey: .domainTagIds)
        try container.encode(status, forKey: .status)
        try container.encode(researchPrompt, forKey: .researchPrompt)
        try container.encode(validationPrompt, forKey: .validationPrompt)
        try container.encodeIfPresent(mindMapImageData, forKey: .mindMapImageData)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
