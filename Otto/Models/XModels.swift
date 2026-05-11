import Foundation

// MARK: - X API v2 Response Types

/// Generic X API v2 paginated response wrapper
struct XPaginatedResponse<T: Codable>: Codable {
    let data: [T]?
    let meta: XPaginationMeta?
    let includes: XIncludes?
}

struct XPaginationMeta: Codable {
    let resultCount: Int?
    let nextToken: String?
    let previousToken: String?

    enum CodingKeys: String, CodingKey {
        case resultCount = "result_count"
        case nextToken = "next_token"
        case previousToken = "previous_token"
    }
}

struct XIncludes: Codable {
    let users: [XAPIUser]?
    let media: [XAPIMedia]?
}

// MARK: - User

struct XAPIUser: Codable {
    let id: String
    let name: String
    let username: String
    let description: String?
    let profileImageUrl: String?
    let publicMetrics: XUserPublicMetrics?

    enum CodingKeys: String, CodingKey {
        case id, name, username, description
        case profileImageUrl = "profile_image_url"
        case publicMetrics = "public_metrics"
    }
}

struct XUserPublicMetrics: Codable {
    let followersCount: Int
    let followingCount: Int
    let tweetCount: Int
    let listedCount: Int?

    enum CodingKeys: String, CodingKey {
        case followersCount = "followers_count"
        case followingCount = "following_count"
        case tweetCount = "tweet_count"
        case listedCount = "listed_count"
    }
}

/// Response for /2/users/me
struct XMeResponse: Codable {
    let data: XAPIUser
}

// MARK: - Tweet

struct XAPITweet: Codable {
    let id: String
    let text: String
    let authorId: String?
    let createdAt: String?
    let publicMetrics: XTweetPublicMetrics?
    let referencedTweets: [XReferencedTweet]?
    let attachments: XAttachments?

    enum CodingKeys: String, CodingKey {
        case id, text
        case authorId = "author_id"
        case createdAt = "created_at"
        case publicMetrics = "public_metrics"
        case referencedTweets = "referenced_tweets"
        case attachments
    }
}

struct XTweetPublicMetrics: Codable {
    let retweetCount: Int
    let replyCount: Int
    let likeCount: Int
    let quoteCount: Int?
    let bookmarkCount: Int?

    enum CodingKeys: String, CodingKey {
        case retweetCount = "retweet_count"
        case replyCount = "reply_count"
        case likeCount = "like_count"
        case quoteCount = "quote_count"
        case bookmarkCount = "bookmark_count"
    }
}

struct XReferencedTweet: Codable {
    let type: String  // "retweeted", "quoted", "replied_to"
    let id: String
}

struct XAttachments: Codable {
    let mediaKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case mediaKeys = "media_keys"
    }
}

// MARK: - Media

struct XAPIMedia: Codable {
    let mediaKey: String
    let type: String  // "photo", "video", "animated_gif"
    let url: String?
    let previewImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case type, url
        case previewImageUrl = "preview_image_url"
    }
}

// MARK: - DM Events

struct XAPIDMEvent: Codable {
    let id: String
    let text: String?
    let eventType: String
    let senderId: String?
    let dmConversationId: String?
    let createdAt: String?
    let participantIds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, text
        case eventType = "event_type"
        case senderId = "sender_id"
        case dmConversationId = "dm_conversation_id"
        case createdAt = "created_at"
        case participantIds = "participant_ids"
    }
}

// MARK: - OAuth Token Response

struct XTokenResponse: Codable {
    let tokenType: String
    let expiresIn: Int
    let accessToken: String
    let refreshToken: String?
    let scope: String

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
    }
}

