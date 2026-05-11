import Foundation

// MARK: - Gmail API Response Models

/// Response from listing messages
struct GmailMessageList: Codable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

/// Reference to a message (returned in list response)
struct GmailMessageRef: Codable {
    let id: String
    let threadId: String
}

/// Full message details
struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String
    let payload: GmailPayload
    let internalDate: String

    /// Convert internal date (milliseconds since epoch) to Date
    var receivedDate: Date {
        if let millis = Double(internalDate) {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return Date()
    }

    /// Extract subject from headers
    var subject: String {
        payload.headers.first { $0.name.lowercased() == "subject" }?.value ?? "(No Subject)"
    }

    /// Extract sender from headers
    var from: String {
        payload.headers.first { $0.name.lowercased() == "from" }?.value ?? ""
    }

    /// Extract recipients from To and CC headers
    var recipients: [String] {
        var result: [String] = []
        if let to = payload.headers.first(where: { $0.name.lowercased() == "to" })?.value {
            result.append(contentsOf: parseEmailList(to))
        }
        if let cc = payload.headers.first(where: { $0.name.lowercased() == "cc" })?.value {
            result.append(contentsOf: parseEmailList(cc))
        }
        return result
    }

    /// Parse comma-separated email list
    private func parseEmailList(_ list: String) -> [String] {
        list.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Extract plain text body from message
    var plainTextBody: String {
        // Try to get plain text part first
        if let body = findPlainTextBody(in: payload) {
            return body
        }
        // Fall back to HTML body converted to plain text
        if let htmlBody = findHtmlBody(in: payload) {
            return stripHtml(htmlBody)
        }
        // Fall back to snippet
        return snippet
    }

    private func findPlainTextBody(in payload: GmailPayload) -> String? {
        // Check if payload itself is plain text
        if payload.mimeType == "text/plain", let data = payload.body?.data {
            return decodeBase64(data)
        }

        // Check parts recursively
        if let parts = payload.parts {
            for part in parts {
                if part.mimeType == "text/plain", let data = part.body?.data {
                    return decodeBase64(data)
                }
                // Check nested parts (for multipart/alternative)
                if let nestedParts = part.parts {
                    for nestedPart in nestedParts {
                        if nestedPart.mimeType == "text/plain", let data = nestedPart.body?.data {
                            return decodeBase64(data)
                        }
                    }
                }
            }
        }

        return nil
    }

    private func findHtmlBody(in payload: GmailPayload) -> String? {
        // Check if payload itself is HTML
        if payload.mimeType == "text/html", let data = payload.body?.data {
            return decodeBase64(data)
        }

        // Check parts recursively
        if let parts = payload.parts {
            for part in parts {
                if part.mimeType == "text/html", let data = part.body?.data {
                    return decodeBase64(data)
                }
                if let nestedParts = part.parts {
                    for nestedPart in nestedParts {
                        if nestedPart.mimeType == "text/html", let data = nestedPart.body?.data {
                            return decodeBase64(data)
                        }
                    }
                }
            }
        }

        return nil
    }

    private func decodeBase64(_ data: String) -> String? {
        // Gmail uses URL-safe base64 encoding
        let base64 = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let decodedData = Data(base64Encoded: padded) else { return nil }
        return String(data: decodedData, encoding: .utf8)
    }

    private func stripHtml(_ html: String) -> String {
        // Basic HTML stripping
        var result = html

        // Remove style and script tags with content
        result = result.replacingOccurrences(of: "<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "<script[^>]*>.*?</script>", with: "", options: .regularExpression)

        // Replace common HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")

        // Add line breaks for block elements
        result = result.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</p>", with: "\n")
        result = result.replacingOccurrences(of: "<div[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</div>", with: "\n")

        // Remove all remaining HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Clean up whitespace
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }
}

/// Message payload containing headers and body
struct GmailPayload: Codable {
    let mimeType: String?
    let headers: [GmailHeader]
    let body: GmailBody?
    let parts: [GmailPart]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        headers = try container.decodeIfPresent([GmailHeader].self, forKey: .headers) ?? []
        body = try container.decodeIfPresent(GmailBody.self, forKey: .body)
        parts = try container.decodeIfPresent([GmailPart].self, forKey: .parts)
    }

    private enum CodingKeys: String, CodingKey {
        case mimeType, headers, body, parts
    }
}

/// Email header (name-value pair)
struct GmailHeader: Codable {
    let name: String
    let value: String
}

/// Message body data
struct GmailBody: Codable {
    let size: Int?
    let data: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        data = try container.decodeIfPresent(String.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case size, data
    }
}

/// Message part (for multipart messages)
struct GmailPart: Codable {
    let partId: String?
    let mimeType: String
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partId = try container.decodeIfPresent(String.self, forKey: .partId)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        headers = try container.decodeIfPresent([GmailHeader].self, forKey: .headers)
        body = try container.decodeIfPresent(GmailBody.self, forKey: .body)
        parts = try container.decodeIfPresent([GmailPart].self, forKey: .parts)
    }

    private enum CodingKeys: String, CodingKey {
        case partId, mimeType, filename, headers, body, parts
    }
}

// MARK: - OAuth Token Response

struct GoogleTokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

// MARK: - Helper to Parse Email Address

extension String {
    /// Extract email address from "Name <email@example.com>" format
    var extractedEmailAddress: String {
        if let match = self.range(of: "<([^>]+)>", options: .regularExpression) {
            var email = String(self[match])
            email.removeFirst() // Remove <
            email.removeLast() // Remove >
            return email
        }
        return self.trimmingCharacters(in: .whitespaces)
    }

    /// Extract display name from "Name <email@example.com>" format
    var extractedDisplayName: String? {
        if let angleIndex = self.firstIndex(of: "<") {
            let name = String(self[..<angleIndex]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name.replacingOccurrences(of: "\"", with: "")
        }
        return nil
    }
}
