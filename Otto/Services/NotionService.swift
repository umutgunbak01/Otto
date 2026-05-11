import Foundation

actor NotionService {
    static let shared = NotionService()

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"
    private let userDefaultsKey = "notion_api_token"

    private var apiToken: String {
        UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
    }

    private init() {}

    // MARK: - API Token Management

    nonisolated func setAPIToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "notion_api_token")
    }

    nonisolated func getAPIToken() -> String {
        UserDefaults.standard.string(forKey: "notion_api_token") ?? ""
    }

    nonisolated func hasAPIToken() -> Bool {
        if let token = UserDefaults.standard.string(forKey: "notion_api_token"), !token.isEmpty {
            return true
        }
        return false
    }

    nonisolated func clearAPIToken() {
        UserDefaults.standard.removeObject(forKey: "notion_api_token")
    }

    // MARK: - API Requests

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let token = apiToken
        guard !token.isEmpty else {
            NSLog("[Notion] No API token configured")
            throw NotionError.noAPIToken
        }

        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw NotionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")

        if let body = body {
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...204:
            return data
        default:
            // Status + path are useful diagnostics; the response body can
            // carry page titles, workspace IDs, and user emails depending on
            // the error, so we don't write it to the system log.
            NSLog("[Notion] API error %d for %@", httpResponse.statusCode, path)
            switch httpResponse.statusCode {
            case 401:
                throw NotionError.unauthorized
            case 403:
                throw NotionError.forbidden
            case 429:
                throw NotionError.rateLimited
            default:
                throw NotionError.apiError(statusCode: httpResponse.statusCode)
            }
        }
    }

    // MARK: - Search Pages

    /// Fetch all pages shared with the integration
    func searchPages() async throws -> [NotionPage] {
        var allPages: [NotionPage] = []
        var startCursor: String? = nil

        repeat {
            var bodyDict: [String: Any] = [
                "filter": ["property": "object", "value": "page"],
                "page_size": 100
            ]
            if let cursor = startCursor {
                bodyDict["start_cursor"] = cursor
            }

            let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
            let data = try await makeRequest(path: "/search", method: "POST", body: bodyData)

            // Try decoding — log raw JSON on failure for debugging
            do {
                let response = try JSONDecoder().decode(NotionSearchResponse.self, from: data)
                allPages.append(contentsOf: response.results)

                if response.hasMore, let next = response.nextCursor {
                    startCursor = next
                } else {
                    startCursor = nil
                }
            } catch {
                if let json = String(data: data.prefix(2000), encoding: .utf8) {
                    print("[Notion] Failed to decode search response: \(error)")
                    print("[Notion] Raw response (first 2000 chars): \(json)")
                }
                throw error
            }
        } while startCursor != nil

        return allPages
    }

    // MARK: - Fetch Page Blocks

    /// Fetch all top-level blocks for a page
    func fetchPageBlocks(pageId: String) async throws -> [NotionBlock] {
        var allBlocks: [NotionBlock] = []
        var startCursor: String? = nil

        repeat {
            var path = "/blocks/\(pageId)/children?page_size=100"
            if let cursor = startCursor {
                path += "&start_cursor=\(cursor)"
            }

            let data = try await makeRequest(path: path)
            let response = try JSONDecoder().decode(NotionBlocksResponse.self, from: data)

            allBlocks.append(contentsOf: response.results)

            if response.hasMore, let next = response.nextCursor {
                startCursor = next
            } else {
                startCursor = nil
            }
        } while startCursor != nil

        return allBlocks
    }

    // MARK: - Validate Token

    /// Validate the API token with a lightweight single-page search
    func validateToken() async throws -> Bool {
        let bodyDict: [String: Any] = [
            "filter": ["property": "object", "value": "page"],
            "page_size": 1
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        _ = try await makeRequest(path: "/search", method: "POST", body: bodyData)
        return true
    }

    // MARK: - Convert Blocks to Markdown

    /// Convert Notion blocks to the app's markdown-like content format
    func convertBlocksToMarkdown(_ blocks: [NotionBlock]) -> String {
        var lines: [String] = []

        for block in blocks {
            switch block.type {
            case "paragraph":
                let text = extractPlainText(block.paragraph?.richText)
                lines.append(text)

            case "heading_1":
                let text = extractPlainText(block.heading1?.richText)
                lines.append("# \(text)")

            case "heading_2":
                let text = extractPlainText(block.heading2?.richText)
                lines.append("## \(text)")

            case "heading_3":
                let text = extractPlainText(block.heading3?.richText)
                lines.append("### \(text)")

            case "bulleted_list_item":
                let text = extractPlainText(block.bulletedListItem?.richText)
                lines.append("- \(text)")

            case "numbered_list_item":
                let text = extractPlainText(block.numberedListItem?.richText)
                lines.append("1. \(text)")

            case "to_do":
                if let todo = block.toDo {
                    let text = extractPlainText(todo.richText)
                    let checkbox = todo.checked ? "- [x]" : "- [ ]"
                    lines.append("\(checkbox) \(text)")
                }

            case "quote":
                let text = extractPlainText(block.quote?.richText)
                lines.append("> \(text)")

            case "divider":
                lines.append("---")

            case "code":
                let text = extractPlainText(block.code?.richText)
                lines.append(text)

            default:
                // Unsupported block types — skip
                break
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Extract plain text from a rich text array
    private func extractPlainText(_ richText: [NotionRichText]?) -> String {
        guard let richText = richText else { return "" }
        return richText.map { $0.plainText }.joined()
    }

    // MARK: - Convert to Notes

    /// Convert Notion pages and their blocks to Otto Note models
    func convertToNotes(_ pages: [NotionPage], blocks: [String: [NotionBlock]]) -> [Note] {
        return pages.compactMap { page in
            let title = extractPageTitle(page)
            let pageBlocks = blocks[page.id] ?? []
            let content = convertBlocksToMarkdown(pageBlocks)

            // Parse dates from Notion's ISO 8601 format
            let createdAt = parseNotionDate(page.createdTime) ?? Date()
            let updatedAt = parseNotionDate(page.lastEditedTime) ?? Date()

            return Note(
                title: title,
                content: content,
                notionPageId: page.id,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    /// Extract the title from a Notion page's properties
    private func extractPageTitle(_ page: NotionPage) -> String {
        // Find the property with type "title"
        for (_, property) in page.properties {
            if property.type == "title", let titleParts = property.title {
                return titleParts.map { $0.plainText }.joined()
            }
        }
        return "Untitled"
    }

    /// Parse Notion's ISO 8601 date string
    private func parseNotionDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}

// MARK: - Helper for lossy decoding

private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
    func encode(to encoder: Encoder) throws {}
}

// MARK: - Notion API Models

struct NotionSearchResponse: Codable {
    let results: [NotionPage]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? container.decode(String.self, forKey: .nextCursor)
        // Lossy array decoding: skip pages that fail to decode
        var resultsContainer = try container.nestedUnkeyedContainer(forKey: .results)
        var decoded: [NotionPage] = []
        while !resultsContainer.isAtEnd {
            if let page = try? resultsContainer.decode(NotionPage.self) {
                decoded.append(page)
            } else {
                // Skip this element by decoding as generic JSON
                _ = try? resultsContainer.decode(AnyCodable.self)
            }
        }
        results = decoded
    }
}

struct NotionPage: Codable {
    let id: String
    let createdTime: String
    let lastEditedTime: String
    let properties: [String: NotionProperty]

    enum CodingKeys: String, CodingKey {
        case id, properties
        case createdTime = "created_time"
        case lastEditedTime = "last_edited_time"
    }
}

struct NotionProperty: Codable {
    let type: String
    let title: [NotionRichText]?

    enum CodingKeys: String, CodingKey {
        case type, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        title = try? container.decode([NotionRichText].self, forKey: .title)
    }
}

struct NotionRichText: Codable {
    let plainText: String

    enum CodingKeys: String, CodingKey {
        case plainText = "plain_text"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainText = (try? container.decode(String.self, forKey: .plainText)) ?? ""
    }
}

struct NotionBlocksResponse: Codable {
    let results: [NotionBlock]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? container.decode(String.self, forKey: .nextCursor)
        // Lossy array decoding: skip blocks that fail to decode
        var resultsContainer = try container.nestedUnkeyedContainer(forKey: .results)
        var decoded: [NotionBlock] = []
        while !resultsContainer.isAtEnd {
            if let block = try? resultsContainer.decode(NotionBlock.self) {
                decoded.append(block)
            } else {
                _ = try? resultsContainer.decode(AnyCodable.self)
            }
        }
        results = decoded
    }
}

struct NotionBlock: Codable {
    let id: String
    let type: String
    let paragraph: NotionBlockContent?
    let heading1: NotionBlockContent?
    let heading2: NotionBlockContent?
    let heading3: NotionBlockContent?
    let bulletedListItem: NotionBlockContent?
    let numberedListItem: NotionBlockContent?
    let toDo: NotionToDoContent?
    let quote: NotionBlockContent?
    let code: NotionCodeContent?
    let divider: NotionEmptyContent?

    enum CodingKeys: String, CodingKey {
        case id, type, paragraph, quote, code, divider
        case heading1 = "heading_1"
        case heading2 = "heading_2"
        case heading3 = "heading_3"
        case bulletedListItem = "bulleted_list_item"
        case numberedListItem = "numbered_list_item"
        case toDo = "to_do"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        paragraph = try? container.decode(NotionBlockContent.self, forKey: .paragraph)
        heading1 = try? container.decode(NotionBlockContent.self, forKey: .heading1)
        heading2 = try? container.decode(NotionBlockContent.self, forKey: .heading2)
        heading3 = try? container.decode(NotionBlockContent.self, forKey: .heading3)
        bulletedListItem = try? container.decode(NotionBlockContent.self, forKey: .bulletedListItem)
        numberedListItem = try? container.decode(NotionBlockContent.self, forKey: .numberedListItem)
        toDo = try? container.decode(NotionToDoContent.self, forKey: .toDo)
        quote = try? container.decode(NotionBlockContent.self, forKey: .quote)
        code = try? container.decode(NotionCodeContent.self, forKey: .code)
        divider = try? container.decode(NotionEmptyContent.self, forKey: .divider)
    }
}

struct NotionBlockContent: Codable {
    let richText: [NotionRichText]

    enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        richText = (try? container.decode([NotionRichText].self, forKey: .richText)) ?? []
    }
}

struct NotionToDoContent: Codable {
    let richText: [NotionRichText]
    let checked: Bool

    enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
        case checked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        richText = (try? container.decode([NotionRichText].self, forKey: .richText)) ?? []
        checked = (try? container.decode(Bool.self, forKey: .checked)) ?? false
    }
}

struct NotionCodeContent: Codable {
    let richText: [NotionRichText]
    let language: String?

    enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
        case language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        richText = (try? container.decode([NotionRichText].self, forKey: .richText)) ?? []
        language = try? container.decode(String.self, forKey: .language)
    }
}

struct NotionEmptyContent: Codable {}

// MARK: - Errors

enum NotionError: LocalizedError {
    case noAPIToken
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case rateLimited
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noAPIToken:
            return "No Notion API token configured. Add your integration token in Integrations."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from Notion"
        case .unauthorized:
            return "Invalid integration token. Please check your Notion integration token."
        case .forbidden:
            return "Access forbidden. Make sure you've shared pages with your Notion integration."
        case .rateLimited:
            return "Too many requests. Please wait a moment and try again."
        case .apiError(let statusCode):
            return "Notion API error (status: \(statusCode))"
        }
    }
}
