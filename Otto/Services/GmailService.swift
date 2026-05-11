import Foundation

actor GmailService {
    static let shared = GmailService()

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let batchSize = 10  // Reduced from 50 to avoid rate limiting
    private let delayBetweenBatches: UInt64 = 500_000_000  // 0.5 seconds between batches
    private let maxRetries = 3

    private init() {}

    // MARK: - Authorized request helper

    /// Wrap a Gmail call so we surface a Gmail-typed error on auth failures.
    /// All retry / refresh logic lives in `GoogleAuthService.performAuthorizedRequest`.
    private func authorizedRequest(_ build: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await GoogleAuthService.shared.performAuthorizedRequest(build)
        } catch GoogleAuthError.refreshFailed, GoogleAuthError.noRefreshToken {
            throw GmailError.needsReauth
        } catch let GoogleAuthError.refreshFailedWithReason(status, body) {
            // Surface Google's actual rejection reason — invalid_grant /
            // invalid_scope / unauthorized_client tells the user *why*
            // reconnecting won't help (e.g. Gmail API not enabled in the
            // Google Cloud project, OAuth consent in Testing mode, account
            // suspended). Keeps debugging non-mysterious.
            throw GmailError.refreshFailedDetail(status: status, body: body)
        } catch GoogleAuthError.invalidResponse {
            throw GmailError.invalidResponse
        }
    }

    // MARK: - Fetch Messages

    /// Fetch list of message references with optional sender exclusions
    func fetchMessages(
        maxResults: Int = 100,
        pageToken: String? = nil,
        excludeSenders: [String] = [],
        sinceDate: Date? = nil,
        labelIds: [String]? = nil
    ) async throws -> GmailMessageList {
        var urlComponents = URLComponents(string: "\(baseURL)/messages")!
        var queryItems = [
            URLQueryItem(name: "maxResults", value: String(min(maxResults, 500)))
        ]

        if let pageToken = pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        // Add label filter if provided
        if let labelIds = labelIds {
            for labelId in labelIds {
                queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
            }
        }

        // Build query string for filtering
        let query = buildQuery(excludeSenders: excludeSenders, sinceDate: sinceDate)
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        urlComponents.queryItems = queryItems
        let url = urlComponents.url!

        let (data, http) = try await authorizedRequest { URLRequest(url: url) }

        guard http.statusCode == 200 else {
            throw GmailError.requestFailed(statusCode: http.statusCode)
        }

        return try JSONDecoder().decode(GmailMessageList.self, from: data)
    }

    /// Fetch full details for a single message with retry logic
    func fetchMessage(id: String, retryCount: Int = 0) async throws -> GmailMessage {
        let url = URL(string: "\(baseURL)/messages/\(id)?format=full")!

        let (data, http) = try await authorizedRequest { URLRequest(url: url) }

        // Handle rate limiting with retry
        if http.statusCode == 429 {
            if retryCount < maxRetries {
                // Exponential backoff: 1s, 2s, 4s
                let delay = UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                return try await fetchMessage(id: id, retryCount: retryCount + 1)
            } else {
                throw GmailError.rateLimited
            }
        }

        guard http.statusCode == 200 else {
            throw GmailError.requestFailed(statusCode: http.statusCode)
        }

        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    /// Fetch multiple messages sequentially with delays to avoid rate limiting
    func fetchMessagesBatch(ids: [String]) async throws -> [GmailMessage] {
        var messages: [GmailMessage] = []

        for (index, id) in ids.enumerated() {
            do {
                let message = try await fetchMessage(id: id)
                messages.append(message)
            } catch GmailError.rateLimited {
                // If we hit rate limit even after retries, wait longer and continue
                print("Rate limited on message \(id), waiting 5 seconds...")
                try await Task.sleep(nanoseconds: 5_000_000_000)
                // Try one more time
                do {
                    let message = try await fetchMessage(id: id)
                    messages.append(message)
                } catch {
                    print("Skipping message \(id) after rate limit")
                }
            } catch {
                print("Failed to fetch message \(id): \(error)")
            }

            // Small delay between each request to avoid rate limiting
            if index < ids.count - 1 {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms between requests
            }
        }

        return messages
    }

    /// Fetch all messages with pagination, excluding blocked senders
    func fetchAllMessages(
        excludeSenders: [String] = [],
        sinceDate: Date? = nil,
        maxTotal: Int? = nil,
        progressCallback: ((Int, Int) -> Void)? = nil,
        batchCallback: (([GmailMessage]) async -> Void)? = nil
    ) async throws -> [GmailMessage] {
        var allMessageIds: [String] = []
        var pageToken: String? = nil

        // First, get all message IDs (this is fast)
        print("Fetching message list...")
        repeat {
            let messageList = try await fetchMessages(
                maxResults: 500,
                pageToken: pageToken,
                excludeSenders: excludeSenders,
                sinceDate: sinceDate
            )

            if let messageRefs = messageList.messages {
                allMessageIds.append(contentsOf: messageRefs.map { $0.id })
            }

            pageToken = messageList.nextPageToken

            // If we have a max limit and reached it, stop
            if let max = maxTotal, allMessageIds.count >= max {
                allMessageIds = Array(allMessageIds.prefix(max))
                break
            }

        } while pageToken != nil

        print("Found \(allMessageIds.count) messages to fetch")

        // Now fetch full details in smaller sequential batches
        var allMessages: [GmailMessage] = []
        let totalToFetch = allMessageIds.count

        for batchStart in stride(from: 0, to: totalToFetch, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalToFetch)
            let batchIds = Array(allMessageIds[batchStart..<batchEnd])

            let batchMessages = try await fetchMessagesBatch(ids: batchIds)
            allMessages.append(contentsOf: batchMessages)

            await batchCallback?(batchMessages)

            // Report progress
            progressCallback?(allMessages.count, totalToFetch)
            print("Fetched \(allMessages.count)/\(totalToFetch) messages")

            // Delay between batches to avoid rate limiting
            if batchEnd < totalToFetch {
                try await Task.sleep(nanoseconds: delayBetweenBatches)
            }
        }

        return allMessages
    }

    /// Fetch recent messages (for incremental sync)
    func fetchRecentMessages(
        excludeSenders: [String] = [],
        sinceDate: Date?,
        maxResults: Int = 100
    ) async throws -> [GmailMessage] {
        // Get message IDs
        let messageList = try await fetchMessages(
            maxResults: maxResults,
            excludeSenders: excludeSenders,
            sinceDate: sinceDate
        )

        guard let messageRefs = messageList.messages else {
            return []
        }

        // Fetch full details
        return try await fetchMessagesBatch(ids: messageRefs.map { $0.id })
    }

    // MARK: - Query Building

    /// Build Gmail search query with sender exclusions and date filter
    private func buildQuery(excludeSenders: [String], sinceDate: Date?) -> String {
        var queryParts: [String] = []

        // Exclude blocked senders at API level
        for sender in excludeSenders {
            queryParts.append("-from:\(sender)")
        }

        // Add date filter if provided
        if let date = sinceDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            queryParts.append("after:\(formatter.string(from: date))")
        }

        return queryParts.joined(separator: " ")
    }

    // MARK: - Convert to Email Model

    /// Convert GmailMessage to our Email model
    func convertToEmail(_ gmailMessage: GmailMessage) -> Email {
        let from = gmailMessage.from
        let senderEmail = from.extractedEmailAddress
        let senderName = from.extractedDisplayName

        return Email(
            gmailId: gmailMessage.id,
            threadId: gmailMessage.threadId,
            subject: gmailMessage.subject,
            sender: senderEmail,
            senderName: senderName,
            recipients: gmailMessage.recipients.map { $0.extractedEmailAddress },
            body: gmailMessage.plainTextBody,
            receivedDate: gmailMessage.receivedDate,
            isRead: !(gmailMessage.labelIds?.contains("UNREAD") ?? false),
            labels: gmailMessage.labelIds ?? [],
            snippet: gmailMessage.snippet
        )
    }

    /// Convert array of GmailMessages to Email models
    func convertToEmails(_ gmailMessages: [GmailMessage]) -> [Email] {
        gmailMessages.map { convertToEmail($0) }
    }

    // MARK: - Authentication Status

    func isAuthenticated() -> Bool {
        GoogleAuthService.shared.isAuthenticated()
    }
}

// MARK: - Errors

enum GmailError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int)
    case notAuthenticated
    case rateLimited
    case needsReauth
    case refreshFailedDetail(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .requestFailed(let statusCode):
            return "Gmail API request failed with status code: \(statusCode)"
        case .notAuthenticated:
            return "Not authenticated with Gmail. Please sign in."
        case .rateLimited:
            return "Gmail API rate limit exceeded. Please try again later."
        case .needsReauth:
            return "Gmail access expired. Disconnect and reconnect Gmail to refresh permissions."
        case .refreshFailedDetail(let status, let body):
            return "Gmail token refresh failed (HTTP \(status)). Google said: \(body)"
        }
    }
}
