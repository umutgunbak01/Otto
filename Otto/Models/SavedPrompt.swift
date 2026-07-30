import Foundation

/// One reusable prompt in the user's library. Insertable from the chat
/// composer's bookmark picker, manageable in the Automations tab, and
/// creatable by the agent via the `save_prompt` tool. A recurring task
/// copies a prompt's text at creation — no live reference, so deleting a
/// saved prompt never breaks a schedule.
struct SavedPrompt: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, createdAt, updatedAt, lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        lastUsedAt = try? c.decode(Date.self, forKey: .lastUsedAt)
    }
}
