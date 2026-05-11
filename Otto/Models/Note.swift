import Foundation

struct Note: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var primaryCategory: PrimaryCategory
    var domainTagIds: [UUID]
    var researchPrompt: String
    var mindMapImageData: Data?
    var notionPageId: String?
    var createdAt: Date
    var updatedAt: Date

    // Custom CodingKeys to support migration from old data
    enum CodingKeys: String, CodingKey {
        case id, title, content, primaryCategory, domainTagIds
        case researchPrompt, mindMapImageData, notionPageId
        case researchFindings // Old field name for migration
        case createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        primaryCategory: PrimaryCategory = .personal,
        domainTagIds: [UUID] = [],
        researchPrompt: String = "",
        mindMapImageData: Data? = nil,
        notionPageId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.primaryCategory = primaryCategory
        self.domainTagIds = domainTagIds
        self.researchPrompt = researchPrompt
        self.mindMapImageData = mindMapImageData
        self.notionPageId = notionPageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoder to handle migration from old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        primaryCategory = try container.decode(PrimaryCategory.self, forKey: .primaryCategory)
        domainTagIds = try container.decode([UUID].self, forKey: .domainTagIds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Try new field name first, fall back to old field name for migration
        if let prompt = try? container.decode(String.self, forKey: .researchPrompt) {
            researchPrompt = prompt
        } else if let findings = try? container.decode(String.self, forKey: .researchFindings) {
            researchPrompt = findings
        } else {
            researchPrompt = ""
        }

        // Mind map is optional
        mindMapImageData = try? container.decode(Data.self, forKey: .mindMapImageData)

        // Notion page ID is optional
        notionPageId = try? container.decode(String.self, forKey: .notionPageId)
    }

    // Custom encoder to use new field name
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(primaryCategory, forKey: .primaryCategory)
        try container.encode(domainTagIds, forKey: .domainTagIds)
        try container.encode(researchPrompt, forKey: .researchPrompt)
        try container.encodeIfPresent(mindMapImageData, forKey: .mindMapImageData)
        try container.encodeIfPresent(notionPageId, forKey: .notionPageId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
