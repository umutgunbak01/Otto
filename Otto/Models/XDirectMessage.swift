import Foundation

struct XDirectMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var xMessageId: String
    var senderId: String
    var senderUsername: String
    var senderDisplayName: String
    var recipientId: String
    var text: String
    var createdAt: Date
    var conversationId: String
    var syncUpdatedAt: Date

    init(
        id: UUID = UUID(),
        xMessageId: String,
        senderId: String = "",
        senderUsername: String = "",
        senderDisplayName: String = "",
        recipientId: String = "",
        text: String = "",
        createdAt: Date = Date(),
        conversationId: String = "",
        syncUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.xMessageId = xMessageId
        self.senderId = senderId
        self.senderUsername = senderUsername
        self.senderDisplayName = senderDisplayName
        self.recipientId = recipientId
        self.text = text
        self.createdAt = createdAt
        self.conversationId = conversationId
        self.syncUpdatedAt = syncUpdatedAt
    }

    // MARK: - Computed

    var searchableContent: String {
        [text, senderUsername, senderDisplayName].joined(separator: " ")
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
