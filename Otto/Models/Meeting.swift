import Foundation

struct Meeting: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var overview: String
    var actionItems: String
    var participants: [String]
    var organizer: String
    var duration: Int // in seconds
    var meetingDate: Date
    var domainTagIds: [UUID]
    var firefliesId: String? // Link to Fireflies transcript ID
    /// Locally-captured transcript ("[HH:mm:ss] Me: …" lines) for meetings
    /// recorded by Otto itself. Fireflies meetings leave this nil and fetch
    /// their transcript live via `firefliesId`. Optional so meetings saved
    /// before this field existed keep decoding.
    var transcript: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        overview: String = "",
        actionItems: String = "",
        participants: [String] = [],
        organizer: String = "",
        duration: Int = 0,
        meetingDate: Date = Date(),
        domainTagIds: [UUID] = [],
        firefliesId: String? = nil,
        transcript: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.overview = overview
        self.actionItems = actionItems
        self.participants = participants
        self.organizer = organizer
        self.duration = duration
        self.meetingDate = meetingDate
        self.domainTagIds = domainTagIds
        self.firefliesId = firefliesId
        self.transcript = transcript
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this meeting has a transcript available to show — either a
    /// Fireflies transcript fetched live via `firefliesId`, or a transcript
    /// captured locally by Otto's own meeting recorder (stored in `transcript`).
    /// The Meetings list uses this to decide the transcript chip; previously it
    /// keyed only off `firefliesId`, so locally-recorded meetings wrongly showed
    /// "no transcript" even though the transcript was right there.
    var hasTranscript: Bool {
        if firefliesId != nil { return true }
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    var formattedDuration: String {
        let minutes = duration / 60
        if minutes < 60 {
            return "\(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
    }

    var formattedMeetingDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: meetingDate)
    }
}
