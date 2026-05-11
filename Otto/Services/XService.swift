import Foundation

actor XService {
    static let shared = XService()

    private let baseURL = "https://api.x.com/2"
    private let maxRetries = 3

    private init() {}

    // MARK: - Generic Request

    private func makeRequest(path: String, queryItems: [URLQueryItem] = [], retryCount: Int = 0) async throws -> Data {
        let accessToken = try await XAuthService.shared.getValidAccessToken()

        var components = URLComponents(string: "\(baseURL)\(path)")!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw XServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XServiceError.invalidResponse
        }

        // Handle rate limiting with retry
        if httpResponse.statusCode == 429 {
            if retryCount < maxRetries {
                // Check for Retry-After header
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) } ?? pow(2.0, Double(retryCount))
                let delay = UInt64(retryAfter * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
                return try await makeRequest(path: path, queryItems: queryItems, retryCount: retryCount + 1)
            } else {
                throw XServiceError.rateLimited
            }
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 403 {
                // Extract endpoint name from path for clearer error
                let endpoint = path.split(separator: "/").last.map(String.init) ?? path
                throw XServiceError.insufficientTier(endpoint: endpoint)
            }
            throw XServiceError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return data
    }

    // MARK: - Fetch Authenticated User

    func fetchMe() async throws -> XAPIUser {
        let data = try await makeRequest(
            path: "/users/me",
            queryItems: [
                URLQueryItem(name: "user.fields", value: "id,name,username,description,profile_image_url,public_metrics")
            ]
        )
        let response = try JSONDecoder().decode(XMeResponse.self, from: data)
        return response.data
    }

    // MARK: - Fetch My Tweets

    func fetchMyTweets(userId: String, maxResults: Int = 100) async throws -> [XPost] {
        var allPosts: [XPost] = []
        var nextToken: String? = nil

        repeat {
            var queryItems = [
                URLQueryItem(name: "max_results", value: String(min(maxResults, 100))),
                URLQueryItem(name: "tweet.fields", value: "id,text,author_id,created_at,public_metrics,referenced_tweets,attachments"),
                URLQueryItem(name: "expansions", value: "author_id,attachments.media_keys"),
                URLQueryItem(name: "user.fields", value: "id,name,username"),
                URLQueryItem(name: "media.fields", value: "media_key,type,url,preview_image_url")
            ]

            if let nextToken = nextToken {
                queryItems.append(URLQueryItem(name: "pagination_token", value: nextToken))
            }

            let data = try await makeRequest(
                path: "/users/\(userId)/tweets",
                queryItems: queryItems
            )

            let response = try JSONDecoder().decode(XPaginatedResponse<XAPITweet>.self, from: data)
            let userMap = buildUserMap(from: response.includes)
            let mediaMap = buildMediaMap(from: response.includes)

            if let tweets = response.data {
                let posts = tweets.map { tweet in
                    convertToXPost(tweet, userMap: userMap, mediaMap: mediaMap)
                }
                allPosts.append(contentsOf: posts)
            }

            nextToken = response.meta?.nextToken
        } while nextToken != nil

        return allPosts
    }

    // MARK: - Fetch Followers

    /// Returns every follower X will paginate through, each tagged with
    /// `isMutual` so the UI can highlight people you also follow back.
    /// Earlier versions filtered out non-mutuals here, which hid most of
    /// the user's followers — keep the flag, drop the filter.
    func fetchFollowers(userId: String) async throws -> [XFollower] {
        let followers = try await fetchFollowList(userId: userId, path: "/users/\(userId)/followers")
        let following = try await fetchFollowList(userId: userId, path: "/users/\(userId)/following")

        let followingIds = Set(following.map { $0.xUserId })
        return followers.map { follower in
            var tagged = follower
            tagged.isMutual = followingIds.contains(follower.xUserId)
            return tagged
        }
    }

    private func fetchFollowList(userId: String, path: String) async throws -> [XFollower] {
        var allFollowers: [XFollower] = []
        var nextToken: String? = nil

        repeat {
            var queryItems = [
                URLQueryItem(name: "max_results", value: "1000"),
                URLQueryItem(name: "user.fields", value: "id,name,username,description,profile_image_url,public_metrics")
            ]

            if let nextToken = nextToken {
                queryItems.append(URLQueryItem(name: "pagination_token", value: nextToken))
            }

            let data = try await makeRequest(path: path, queryItems: queryItems)
            let response = try JSONDecoder().decode(XPaginatedResponse<XAPIUser>.self, from: data)

            if let users = response.data {
                let followers = users.map { user in
                    XFollower(
                        xUserId: user.id,
                        username: user.username,
                        displayName: user.name,
                        bio: user.description ?? "",
                        profileImageUrl: user.profileImageUrl,
                        followersCount: user.publicMetrics?.followersCount ?? 0,
                        followingCount: user.publicMetrics?.followingCount ?? 0
                    )
                }
                allFollowers.append(contentsOf: followers)
            }

            nextToken = response.meta?.nextToken
        } while nextToken != nil

        return allFollowers
    }

    // MARK: - Fetch Bookmarks

    /// Fetches the authenticated user's bookmarks. Pass `nil` for `userId`
    /// to use the `/users/me/bookmarks` path shortcut — needed on the Free
    /// API tier where `/users/me` is blocked but the bookmarks endpoint
    /// itself is accessible.
    func fetchBookmarks(userId: String?) async throws -> [Bookmark] {
        let userPath = userId ?? "me"
        var allBookmarks: [Bookmark] = []
        var nextToken: String? = nil

        repeat {
            var queryItems = [
                URLQueryItem(name: "max_results", value: "100"),
                URLQueryItem(name: "tweet.fields", value: "id,text,author_id,created_at,public_metrics,attachments"),
                URLQueryItem(name: "expansions", value: "author_id,attachments.media_keys"),
                URLQueryItem(name: "user.fields", value: "id,name,username"),
                URLQueryItem(name: "media.fields", value: "media_key,type,url,preview_image_url")
            ]

            if let nextToken = nextToken {
                queryItems.append(URLQueryItem(name: "pagination_token", value: nextToken))
            }

            let data = try await makeRequest(
                path: "/users/\(userPath)/bookmarks",
                queryItems: queryItems
            )

            let response = try JSONDecoder().decode(XPaginatedResponse<XAPITweet>.self, from: data)
            let userMap = buildUserMap(from: response.includes)

            if let tweets = response.data {
                let bookmarks = tweets.map { tweet -> Bookmark in
                    let authorName = userMap[tweet.authorId ?? ""]?.name ?? "Unknown"
                    let authorUsername = userMap[tweet.authorId ?? ""]?.username ?? ""
                    let tweetUrl = "https://x.com/\(authorUsername)/status/\(tweet.id)"

                    return Bookmark(
                        title: "@\(authorUsername): \(String(tweet.text.prefix(80)))",
                        url: tweetUrl,
                        description: tweet.text,
                        mediaType: .readLater,
                        primaryCategory: .personal,
                        siteName: "X (Twitter)",
                        createdAt: parseISO8601Date(tweet.createdAt) ?? Date()
                    )
                }
                allBookmarks.append(contentsOf: bookmarks)
            }

            nextToken = response.meta?.nextToken
        } while nextToken != nil

        return allBookmarks
    }

    // MARK: - Fetch DMs

    func fetchDMs() async throws -> [XDirectMessage] {
        var allMessages: [XDirectMessage] = []
        var nextToken: String? = nil

        repeat {
            var queryItems = [
                URLQueryItem(name: "max_results", value: "100"),
                // Restrict to actual messages on the wire — otherwise X
                // counts system events (ParticipantsJoin/Leave, conversation
                // create, etc.) against the per-page budget, so each page
                // returns fewer real DMs. The pagination loop already pulls
                // every page X exposes, but a denser response means we
                // recover more history before hitting the endpoint's
                // ~30-day server-side lookback cap.
                URLQueryItem(name: "event_types", value: "MessageCreate"),
                URLQueryItem(name: "dm_event.fields", value: "id,text,event_type,sender_id,dm_conversation_id,created_at,participant_ids"),
                URLQueryItem(name: "expansions", value: "sender_id,participant_ids"),
                URLQueryItem(name: "user.fields", value: "id,name,username")
            ]

            if let nextToken = nextToken {
                queryItems.append(URLQueryItem(name: "pagination_token", value: nextToken))
            }

            let data = try await makeRequest(
                path: "/dm_events",
                queryItems: queryItems
            )

            let response = try JSONDecoder().decode(XPaginatedResponse<XAPIDMEvent>.self, from: data)
            let userMap = buildUserMap(from: response.includes)

            if let events = response.data {
                let messages = events.compactMap { event -> XDirectMessage? in
                    guard event.eventType == "MessageCreate" else { return nil }

                    let sender = userMap[event.senderId ?? ""]
                    let recipientId = event.participantIds?.first(where: { $0 != event.senderId }) ?? ""

                    return XDirectMessage(
                        xMessageId: event.id,
                        senderId: event.senderId ?? "",
                        senderUsername: sender?.username ?? "",
                        senderDisplayName: sender?.name ?? "",
                        recipientId: recipientId,
                        text: event.text ?? "",
                        createdAt: parseISO8601Date(event.createdAt) ?? Date(),
                        conversationId: event.dmConversationId ?? ""
                    )
                }
                allMessages.append(contentsOf: messages)
            }

            nextToken = response.meta?.nextToken
        } while nextToken != nil

        return allMessages
    }

    // MARK: - Helpers

    private func buildUserMap(from includes: XIncludes?) -> [String: XAPIUser] {
        guard let users = includes?.users else { return [:] }
        return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
    }

    private func buildMediaMap(from includes: XIncludes?) -> [String: XAPIMedia] {
        guard let media = includes?.media else { return [:] }
        return Dictionary(uniqueKeysWithValues: media.map { ($0.mediaKey, $0) })
    }

    private func convertToXPost(_ tweet: XAPITweet, userMap: [String: XAPIUser], mediaMap: [String: XAPIMedia]) -> XPost {
        let author = userMap[tweet.authorId ?? ""]
        let isRetweet = tweet.referencedTweets?.contains(where: { $0.type == "retweeted" }) ?? false
        let isReply = tweet.referencedTweets?.contains(where: { $0.type == "replied_to" }) ?? false

        var mediaUrls: [String] = []
        if let mediaKeys = tweet.attachments?.mediaKeys {
            mediaUrls = mediaKeys.compactMap { key in
                mediaMap[key]?.url ?? mediaMap[key]?.previewImageUrl
            }
        }

        return XPost(
            xPostId: tweet.id,
            authorId: tweet.authorId ?? "",
            authorUsername: author?.username ?? "",
            authorDisplayName: author?.name ?? "",
            text: tweet.text,
            createdAt: parseISO8601Date(tweet.createdAt) ?? Date(),
            likeCount: tweet.publicMetrics?.likeCount ?? 0,
            retweetCount: tweet.publicMetrics?.retweetCount ?? 0,
            replyCount: tweet.publicMetrics?.replyCount ?? 0,
            mediaUrls: mediaUrls,
            isRetweet: isRetweet,
            isReply: isReply
        )
    }

    private func parseISO8601Date(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Errors

enum XServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(statusCode: Int)
    case rateLimited
    case notAuthenticated
    case insufficientTier(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid X API URL"
        case .invalidResponse:
            return "Invalid response from X API"
        case .requestFailed(let statusCode):
            return "X API request failed with status code: \(statusCode)"
        case .rateLimited:
            return "X API rate limit exceeded. Please try again later."
        case .notAuthenticated:
            return "Not authenticated with X. Please sign in."
        case .insufficientTier(let endpoint):
            return "Your X API plan doesn't include read access to \(endpoint). Enable pay-per-use billing or upgrade your tier at developer.x.com."
        }
    }

    var isAccessDenied: Bool {
        switch self {
        case .requestFailed(let statusCode): return statusCode == 403
        case .insufficientTier: return true
        default: return false
        }
    }
}
