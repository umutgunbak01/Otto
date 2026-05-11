import Foundation

struct XPost: Identifiable, Codable, Hashable {
    let id: UUID
    var xPostId: String
    var authorId: String
    var authorUsername: String
    var authorDisplayName: String
    var text: String
    var createdAt: Date
    var likeCount: Int
    var retweetCount: Int
    var replyCount: Int
    var mediaUrls: [String]
    var isRetweet: Bool
    var isReply: Bool
    var syncUpdatedAt: Date

    init(
        id: UUID = UUID(),
        xPostId: String,
        authorId: String = "",
        authorUsername: String = "",
        authorDisplayName: String = "",
        text: String = "",
        createdAt: Date = Date(),
        likeCount: Int = 0,
        retweetCount: Int = 0,
        replyCount: Int = 0,
        mediaUrls: [String] = [],
        isRetweet: Bool = false,
        isReply: Bool = false,
        syncUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.xPostId = xPostId
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.authorDisplayName = authorDisplayName
        self.text = text
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.retweetCount = retweetCount
        self.replyCount = replyCount
        self.mediaUrls = mediaUrls
        self.isRetweet = isRetweet
        self.isReply = isReply
        self.syncUpdatedAt = syncUpdatedAt
    }

    // MARK: - Computed

    var engagementTotal: Int {
        likeCount + retweetCount + replyCount
    }

    var searchableContent: String {
        [text, authorUsername, authorDisplayName].joined(separator: " ")
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
