import Foundation

struct CalendarEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let googleEventId: String
    let calendarId: String
    var title: String
    var description: String?
    var startTime: Date
    var endTime: Date
    var isAllDay: Bool
    var location: String?
    var attendees: [String]
    var htmlLink: String?
    let importedAt: Date

    init(
        id: UUID = UUID(),
        googleEventId: String,
        calendarId: String,
        title: String,
        description: String? = nil,
        startTime: Date,
        endTime: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        attendees: [String] = [],
        htmlLink: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.googleEventId = googleEventId
        self.calendarId = calendarId
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.location = location
        self.attendees = attendees
        self.htmlLink = htmlLink
        self.importedAt = importedAt
    }

    // MARK: - Computed Properties

    var formattedTimeRange: String {
        if isAllDay {
            return "All day"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let start = formatter.string(from: startTime)
        let end = formatter.string(from: endTime)

        return "\(start)-\(end)"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: startTime)
    }

    var durationInMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(startTime)
    }

    var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(startTime)
    }

    var isPast: Bool {
        endTime < Date()
    }

    var startOfDay: Date {
        Calendar.current.startOfDay(for: startTime)
    }
}
