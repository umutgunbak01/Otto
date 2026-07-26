import Foundation

/// One persistent agent-memory note — a durable fact, preference, or standing
/// instruction the agent carries into every future conversation. Injected into
/// the system prompt each turn and curated by the agent itself via the
/// `remember` / `update_memory` tools (and by the user in Settings → Agent).
struct AgentMemoryEntry: Identifiable, Codable, Hashable {
    /// Loose grouping used for prompt display and Settings filtering.
    enum Category: String, Codable, CaseIterable {
        case preference   // how the user likes things done
        case instruction  // standing orders ("always X when Y")
        case fact         // durable facts about the user / people / projects
        case context      // ongoing situations worth carrying forward

        var displayName: String { rawValue.capitalized }
    }

    let id: UUID
    var content: String
    var category: Category
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        category: Category = .fact,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, category, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        category = (try? c.decode(Category.self, forKey: .category)) ?? .fact
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}
