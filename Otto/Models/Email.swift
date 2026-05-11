import Foundation

struct Email: Identifiable, Codable {
    let id: UUID
    let gmailId: String
    let threadId: String
    var subject: String
    var sender: String
    var senderName: String?
    var recipients: [String]
    var body: String
    var receivedDate: Date
    var isRead: Bool
    var labels: [String]
    var snippet: String
    let importedAt: Date

    init(
        id: UUID = UUID(),
        gmailId: String,
        threadId: String,
        subject: String,
        sender: String,
        senderName: String? = nil,
        recipients: [String] = [],
        body: String,
        receivedDate: Date,
        isRead: Bool = false,
        labels: [String] = [],
        snippet: String,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.gmailId = gmailId
        self.threadId = threadId
        self.subject = subject
        self.sender = sender
        self.senderName = senderName
        self.recipients = recipients
        self.body = body
        self.receivedDate = receivedDate
        self.isRead = isRead
        self.labels = labels
        self.snippet = snippet
        self.importedAt = importedAt
    }

    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        gmailId = try container.decode(String.self, forKey: .gmailId)
        threadId = try container.decode(String.self, forKey: .threadId)
        subject = try container.decode(String.self, forKey: .subject)
        sender = try container.decode(String.self, forKey: .sender)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        recipients = try container.decodeIfPresent([String].self, forKey: .recipients) ?? []
        body = try container.decode(String.self, forKey: .body)
        receivedDate = try container.decode(Date.self, forKey: .receivedDate)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, gmailId, threadId, subject, sender, senderName
        case recipients, body, receivedDate, isRead, labels, snippet, importedAt
    }

    /// Display name for the sender (name if available, otherwise email)
    var displaySender: String {
        senderName ?? sender
    }

    /// Formatted date string for display
    var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(receivedDate) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(receivedDate) {
            return "Yesterday"
        } else if calendar.isDate(receivedDate, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE"
        } else if calendar.isDate(receivedDate, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }

        return formatter.string(from: receivedDate)
    }

    /// Short preview of the email body
    var preview: String {
        if !snippet.isEmpty {
            return snippet
        }
        let cleanBody = body.replacingOccurrences(of: "\n", with: " ")
        return String(cleanBody.prefix(150))
    }
}
