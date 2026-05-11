import Foundation

actor GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private let baseURL = "https://www.googleapis.com/calendar/v3"
    private let maxRetries = 3

    private init() {}

    // MARK: - Authorized request helper

    /// Wrap a Calendar call so we surface a Calendar-typed error on auth
    /// failures. All retry / refresh logic lives in
    /// `GoogleAuthService.performAuthorizedRequest` — including the case where
    /// Google has revoked the token server-side and our local expiry check
    /// would otherwise miss it.
    private func authorizedRequest(_ build: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await GoogleAuthService.shared.performAuthorizedRequest(build)
        } catch GoogleAuthError.refreshFailed, GoogleAuthError.noRefreshToken {
            throw GoogleCalendarError.needsReauth
        } catch GoogleAuthError.invalidResponse {
            throw GoogleCalendarError.invalidResponse
        }
    }

    // MARK: - Fetch Events

    /// Fetch events from primary calendar within a date range
    func fetchEvents(
        from startDate: Date,
        to endDate: Date,
        calendarId: String = "primary",
        maxResults: Int = 250
    ) async throws -> [CalendarEvent] {
        var urlComponents = URLComponents(string: "\(baseURL)/calendars/\(calendarId)/events")!
        urlComponents.queryItems = [
            URLQueryItem(name: "timeMin", value: formatDateRFC3339(startDate)),
            URLQueryItem(name: "timeMax", value: formatDateRFC3339(endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),  // Expand recurring events
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]

        var allEvents: [CalendarEvent] = []
        var pageToken: String? = nil

        repeat {
            var components = urlComponents
            if let token = pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: token))
            }
            let url = components.url!

            let (data, http) = try await authorizedRequest { URLRequest(url: url) }

            // Handle rate limiting
            if http.statusCode == 429 {
                throw GoogleCalendarError.rateLimited
            }

            guard http.statusCode == 200 else {
                throw GoogleCalendarError.requestFailed(statusCode: http.statusCode)
            }

            let eventList = try JSONDecoder().decode(GoogleCalendarEventList.self, from: data)

            if let items = eventList.items {
                let events = items.compactMap { $0.toCalendarEvent(calendarId: calendarId) }
                allEvents.append(contentsOf: events)
            }

            pageToken = eventList.nextPageToken
        } while pageToken != nil

        return allEvents
    }

    /// Fetch events for the next N days
    func fetchUpcomingEvents(days: Int = 30, includeToday: Bool = true) async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        let startDate = includeToday ? calendar.startOfDay(for: Date()) : Date()
        guard let endDate = calendar.date(byAdding: .day, value: days, to: startDate) else {
            throw GoogleCalendarError.invalidDateRange
        }

        return try await fetchEvents(from: startDate, to: endDate)
    }

    /// Fetch events including past N days and future N days
    func fetchEventsRange(pastDays: Int = 7, futureDays: Int = 30) async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        guard let startDate = calendar.date(byAdding: .day, value: -pastDays, to: today),
              let endDate = calendar.date(byAdding: .day, value: futureDays, to: today) else {
            throw GoogleCalendarError.invalidDateRange
        }

        return try await fetchEvents(from: startDate, to: endDate)
    }

    /// Fetch a single event by ID
    func fetchEvent(eventId: String, calendarId: String = "primary", retryCount: Int = 0) async throws -> CalendarEvent {
        let url = URL(string: "\(baseURL)/calendars/\(calendarId)/events/\(eventId)")!

        let (data, http) = try await authorizedRequest { URLRequest(url: url) }

        // Handle rate limiting with retry
        if http.statusCode == 429 {
            if retryCount < maxRetries {
                let delay = UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                return try await fetchEvent(eventId: eventId, calendarId: calendarId, retryCount: retryCount + 1)
            } else {
                throw GoogleCalendarError.rateLimited
            }
        }

        guard http.statusCode == 200 else {
            throw GoogleCalendarError.requestFailed(statusCode: http.statusCode)
        }

        let googleEvent = try JSONDecoder().decode(GoogleCalendarEvent.self, from: data)

        guard let event = googleEvent.toCalendarEvent(calendarId: calendarId) else {
            throw GoogleCalendarError.invalidEventData
        }

        return event
    }

    // MARK: - Calendar List

    /// Fetch list of calendars the user has access to
    func fetchCalendarList() async throws -> [GoogleCalendarListEntry] {
        let url = URL(string: "\(baseURL)/users/me/calendarList")!

        let (data, http) = try await authorizedRequest { URLRequest(url: url) }

        guard http.statusCode == 200 else {
            throw GoogleCalendarError.requestFailed(statusCode: http.statusCode)
        }

        let calendarList = try JSONDecoder().decode(GoogleCalendarList.self, from: data)

        return calendarList.items ?? []
    }

    // MARK: - Helpers

    private func formatDateRFC3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Authentication Status

    func isAuthenticated() -> Bool {
        GoogleAuthService.shared.isAuthenticated()
    }
}

// MARK: - Errors

enum GoogleCalendarError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int)
    case notAuthenticated
    case rateLimited
    case invalidDateRange
    case invalidEventData
    case needsReauth

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Google Calendar API"
        case .requestFailed(let statusCode):
            return "Google Calendar API request failed with status code: \(statusCode)"
        case .notAuthenticated:
            return "Not authenticated with Google. Please sign in."
        case .rateLimited:
            return "Google Calendar API rate limit exceeded. Please try again later."
        case .invalidDateRange:
            return "Invalid date range specified"
        case .invalidEventData:
            return "Could not parse event data"
        case .needsReauth:
            return "Google Calendar access expired. Reconnect Google to refresh permissions."
        }
    }
}
