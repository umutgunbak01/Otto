import Foundation

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var primaryCategory: PrimaryCategory
    var domainTagIds: [UUID]
    var researchPrompt: String
    var mindMapImageData: Data?
    var notionPageId: String?
    /// Emoji shown next to the title and in the sidebar (Notion-style page icon).
    var icon: String?
    /// Pinned notes surface in their own sidebar section above the date groups.
    var isPinned: Bool
    /// Soft-delete timestamp. A non-nil value means the note is in the Trash;
    /// it is hidden from lists, search, mentions, and agent tools until
    /// restored, and purged for good ~30 days later.
    var deletedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    // Custom CodingKeys to support migration from old data
    enum CodingKeys: String, CodingKey {
        case id, title, content, primaryCategory, domainTagIds
        case researchPrompt, mindMapImageData, notionPageId
        case icon, isPinned, deletedAt
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
        icon: String? = nil,
        isPinned: Bool = false,
        deletedAt: Date? = nil,
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
        self.icon = icon
        self.isPinned = isPinned
        self.deletedAt = deletedAt
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

        // Newer fields — absent in older data
        icon = try? container.decode(String.self, forKey: .icon)
        isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
        deletedAt = try? container.decode(Date.self, forKey: .deletedAt)
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
        try container.encodeIfPresent(icon, forKey: .icon)
        if isPinned { try container.encode(isPinned, forKey: .isPinned) }
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
