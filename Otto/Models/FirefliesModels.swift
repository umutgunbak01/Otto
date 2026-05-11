import Foundation

// MARK: - GraphQL Request/Response

struct FirefliesGraphQLRequest: Encodable {
    let query: String
    let variables: FirefliesVariables?

    init(query: String, variables: FirefliesVariables? = nil) {
        self.query = query
        self.variables = variables
    }
}

struct FirefliesVariables: Encodable {
    var transcriptId: String?
    var fromDate: String?
    var toDate: String?
    var participants: [String]?
    var limit: Int?
    var skip: Int?

    init(
        transcriptId: String? = nil,
        fromDate: String? = nil,
        toDate: String? = nil,
        participants: [String]? = nil,
        limit: Int? = nil,
        skip: Int? = nil
    ) {
        self.transcriptId = transcriptId
        self.fromDate = fromDate
        self.toDate = toDate
        self.participants = participants
        self.limit = limit
        self.skip = skip
    }
}

struct FirefliesGraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [FirefliesGraphQLError]?
}

struct FirefliesGraphQLError: Decodable {
    let message: String
}

// MARK: - Transcript Models

struct TranscriptsData: Decodable {
    let transcripts: [FirefliesTranscript]
}

struct TranscriptData: Decodable {
    let transcript: FirefliesTranscript
}

struct FirefliesTranscript: Decodable, Identifiable {
    let id: String
    let title: String?
    let date: Double? // Unix timestamp in milliseconds
    let duration: Double? // Duration in minutes (can be fractional)
    let organizer_email: String?
    let participants: [String]?
    let summary: FirefliesSummary?

    var formattedDate: String {
        guard let timestamp = date else { return "Unknown date" }
        // Convert milliseconds to seconds
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        return displayFormatter.string(from: date)
    }

    var formattedDuration: String {
        guard let duration = duration else { return "" }
        let totalMinutes = Int(duration)
        if totalMinutes < 60 {
            return "\(max(1, totalMinutes)) min"
        } else {
            let hours = totalMinutes / 60
            let remainingMinutes = totalMinutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
    }

    /// Returns the date as a Date object for use in Meeting creation
    var dateAsDate: Date? {
        guard let timestamp = date else { return nil }
        return Date(timeIntervalSince1970: timestamp / 1000)
    }

    /// Returns the duration in seconds for use in Meeting creation
    var durationInSeconds: Int {
        guard let duration = duration else { return 0 }
        return Int(duration * 60) // duration appears to be in minutes
    }
}

struct FirefliesSummary: Decodable {
    let overview: String?
    let action_items: String?
    let outline: String?
    let shorthand_bullet: String?
    let keywords: [String]? // API returns array of strings
    let notes: String?

    /// Returns keywords as a comma-separated string for display
    var keywordsString: String? {
        guard let keywords = keywords, !keywords.isEmpty else { return nil }
        return keywords.joined(separator: ", ")
    }
}

// MARK: - Transcript Sentences (raw timestamped transcript)

struct FirefliesSentence: Decodable {
    let speaker_name: String?
    let text: String?
    let start_time: Double? // seconds from start
    let end_time: Double?

    var formattedTime: String {
        guard let start = start_time else { return "" }
        let totalSeconds = Int(start)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct TranscriptSentencesData: Decodable {
    let transcript: TranscriptWithSentences?
}

struct TranscriptWithSentences: Decodable {
    let sentences: [FirefliesSentence]?
}

// MARK: - Import Tracking

struct ImportedMeeting: Codable, Identifiable {
    let id: String // Fireflies transcript ID
    let importedAt: Date
    let meetingId: UUID? // Reference to Meeting model
    let todoIds: [UUID]

    // Custom CodingKeys to support migration from old data (noteId -> meetingId)
    enum CodingKeys: String, CodingKey {
        case id, importedAt, meetingId, noteId, todoIds
    }

    init(id: String, importedAt: Date = Date(), meetingId: UUID? = nil, todoIds: [UUID] = []) {
        self.id = id
        self.importedAt = importedAt
        self.meetingId = meetingId
        self.todoIds = todoIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        todoIds = try container.decode([UUID].self, forKey: .todoIds)
        // Try new field name first, fall back to old field name for migration
        if let meeting = try? container.decode(UUID.self, forKey: .meetingId) {
            meetingId = meeting
        } else {
            meetingId = try? container.decode(UUID.self, forKey: .noteId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(meetingId, forKey: .meetingId)
        try container.encode(todoIds, forKey: .todoIds)
    }
}

// MARK: - Sync Settings

struct FirefliesSyncSettings: Codable {
    var userEmail: String
    var autoSyncEnabled: Bool
    var lastSyncDate: Date?
    var syncIntervalHours: Int

    init(
        userEmail: String = "",
        autoSyncEnabled: Bool = false,
        lastSyncDate: Date? = nil,
        syncIntervalHours: Int = 24
    ) {
        self.userEmail = userEmail
        self.autoSyncEnabled = autoSyncEnabled
        self.lastSyncDate = lastSyncDate
        self.syncIntervalHours = syncIntervalHours
    }

    static let storageKey = "fireflies_sync_settings"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func load() -> FirefliesSyncSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(FirefliesSyncSettings.self, from: data) else {
            return FirefliesSyncSettings()
        }
        return settings
    }
}

// MARK: - GraphQL Queries

enum FirefliesQueries {
    // Basic query with high limit (for manual browsing - fetch all)
    static let transcriptsList = """
    query Transcripts($limit: Int, $skip: Int) {
        transcripts(limit: $limit, skip: $skip) {
            id
            title
            date
            duration
            organizer_email
            participants
            summary {
                overview
                action_items
                keywords
                notes
            }
        }
    }
    """

    // Query with date and participant filters (for auto-sync)
    static let transcriptsFiltered = """
    query Transcripts($fromDate: DateTime, $toDate: DateTime, $participants: [String!], $limit: Int, $skip: Int) {
        transcripts(fromDate: $fromDate, toDate: $toDate, participants: $participants, limit: $limit, skip: $skip) {
            id
            title
            date
            duration
            organizer_email
            participants
            summary {
                overview
                action_items
                keywords
                notes
            }
        }
    }
    """

    static let transcriptSentences = """
    query Transcript($transcriptId: String!) {
        transcript(id: $transcriptId) {
            sentences {
                speaker_name
                text
                start_time
                end_time
            }
        }
    }
    """

    static let transcriptDetail = """
    query Transcript($transcriptId: String!) {
        transcript(id: $transcriptId) {
            id
            title
            date
            duration
            organizer_email
            participants
            summary {
                overview
                action_items
                outline
                shorthand_bullet
                keywords
                notes
            }
        }
    }
    """
}
