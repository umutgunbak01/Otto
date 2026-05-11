import Foundation

// MARK: - Calendar List Response

struct GoogleCalendarList: Codable {
    let kind: String?
    let etag: String?
    let nextPageToken: String?
    let nextSyncToken: String?
    let items: [GoogleCalendarListEntry]?
}

struct GoogleCalendarListEntry: Codable {
    let kind: String?
    let etag: String?
    let id: String
    let summary: String?
    let description: String?
    let timeZone: String?
    let colorId: String?
    let backgroundColor: String?
    let foregroundColor: String?
    let selected: Bool?
    let accessRole: String?
    let primary: Bool?
}

// MARK: - Events List Response

struct GoogleCalendarEventList: Codable {
    let kind: String?
    let etag: String?
    let summary: String?
    let description: String?
    let updated: String?
    let timeZone: String?
    let accessRole: String?
    let nextPageToken: String?
    let nextSyncToken: String?
    let items: [GoogleCalendarEvent]?
}

struct GoogleCalendarEvent: Codable {
    let kind: String?
    let etag: String?
    let id: String
    let status: String?
    let htmlLink: String?
    let created: String?
    let updated: String?
    let summary: String?
    let description: String?
    let location: String?
    let colorId: String?
    let creator: GoogleCalendarPerson?
    let organizer: GoogleCalendarPerson?
    let start: GoogleCalendarDateTime?
    let end: GoogleCalendarDateTime?
    let endTimeUnspecified: Bool?
    let recurrence: [String]?
    let recurringEventId: String?
    let originalStartTime: GoogleCalendarDateTime?
    let transparency: String?
    let visibility: String?
    let iCalUID: String?
    let sequence: Int?
    let attendees: [GoogleCalendarAttendee]?
    let hangoutLink: String?
    let conferenceData: GoogleCalendarConferenceData?
    let eventType: String?

    // Convert to our CalendarEvent model
    func toCalendarEvent(calendarId: String) -> CalendarEvent? {
        guard let startDateTime = start?.toDate(),
              let endDateTime = end?.toDate() else {
            return nil
        }

        let isAllDay = start?.date != nil && start?.dateTime == nil

        return CalendarEvent(
            googleEventId: id,
            calendarId: calendarId,
            title: summary ?? "(No title)",
            description: description,
            startTime: startDateTime,
            endTime: endDateTime,
            isAllDay: isAllDay,
            location: location,
            attendees: attendees?.compactMap { $0.email } ?? [],
            htmlLink: htmlLink
        )
    }
}

struct GoogleCalendarDateTime: Codable {
    let date: String?           // For all-day events: "2024-01-26"
    let dateTime: String?       // For timed events: "2024-01-26T14:00:00+03:00"
    let timeZone: String?

    func toDate() -> Date? {
        if let dateTime = dateTime {
            // ISO8601 datetime
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateTime) {
                return date
            }
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: dateTime)
        } else if let date = date {
            // Date only (all-day event)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            return formatter.date(from: date)
        }
        return nil
    }
}

struct GoogleCalendarPerson: Codable {
    let id: String?
    let email: String?
    let displayName: String?
    let selfItem: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, email, displayName
        case selfItem = "self"
    }
}

struct GoogleCalendarAttendee: Codable {
    let id: String?
    let email: String?
    let displayName: String?
    let organizer: Bool?
    let selfItem: Bool?
    let resource: Bool?
    let optional: Bool?
    let responseStatus: String?
    let comment: String?
    let additionalGuests: Int?

    private enum CodingKeys: String, CodingKey {
        case id, email, displayName, organizer, resource, optional, responseStatus, comment, additionalGuests
        case selfItem = "self"
    }
}

struct GoogleCalendarConferenceData: Codable {
    let createRequest: GoogleCalendarCreateRequest?
    let entryPoints: [GoogleCalendarEntryPoint]?
    let conferenceSolution: GoogleCalendarConferenceSolution?
    let conferenceId: String?
    let signature: String?
    let notes: String?
}

struct GoogleCalendarCreateRequest: Codable {
    let requestId: String?
    let conferenceSolutionKey: GoogleCalendarConferenceSolutionKey?
    let status: GoogleCalendarRequestStatus?
}

struct GoogleCalendarConferenceSolutionKey: Codable {
    let type: String?
}

struct GoogleCalendarRequestStatus: Codable {
    let statusCode: String?
}

struct GoogleCalendarEntryPoint: Codable {
    let entryPointType: String?
    let uri: String?
    let label: String?
    let pin: String?
    let accessCode: String?
    let meetingCode: String?
    let passcode: String?
    let password: String?
}

struct GoogleCalendarConferenceSolution: Codable {
    let key: GoogleCalendarConferenceSolutionKey?
    let name: String?
    let iconUri: String?
}
