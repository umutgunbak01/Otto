import Foundation

/// A unified search result that can represent any content type in the app
struct UniversalSearchResult: Identifiable, Equatable {
    let id: UUID
    let contentType: ContentType
    let title: String
    let subtitle: String?
    let snippet: String?
    let date: Date
    let isArchived: Bool

    // Store item data for opening details
    var todo: Todo?
    var note: Note?
    var idea: Idea?
    var reminder: Reminder?
    var bookmark: Bookmark?
    var meeting: Meeting?
    var email: Email?
    var calendarEvent: CalendarEvent?
    var connection: Connection?
    var file: FileItem?
    var xPost: XPost?
    var xFollower: XFollower?
    var xDirectMessage: XDirectMessage?

    static func == (lhs: UniversalSearchResult, rhs: UniversalSearchResult) -> Bool {
        lhs.id == rhs.id && lhs.contentType == rhs.contentType
    }

    // MARK: - Factory Methods

    static func from(_ todo: Todo) -> UniversalSearchResult {
        UniversalSearchResult(
            id: todo.id,
            contentType: .todo,
            title: todo.title,
            subtitle: todo.dueDate.map { formatDate($0) },
            snippet: todo.description.isEmpty ? nil : String(todo.description.prefix(100)),
            date: todo.updatedAt,
            isArchived: todo.isCompleted,
            todo: todo
        )
    }

    static func from(_ note: Note) -> UniversalSearchResult {
        UniversalSearchResult(
            id: note.id,
            contentType: .note,
            title: note.title,
            subtitle: note.primaryCategory.rawValue,
            snippet: note.content.isEmpty ? nil : String(note.content.prefix(100)),
            date: note.updatedAt,
            isArchived: false,
            note: note
        )
    }

    static func from(_ idea: Idea) -> UniversalSearchResult {
        UniversalSearchResult(
            id: idea.id,
            contentType: .idea,
            title: idea.title,
            subtitle: idea.status.rawValue,
            snippet: idea.content.isEmpty ? nil : String(idea.content.prefix(100)),
            date: idea.updatedAt,
            isArchived: idea.status == .archived,
            idea: idea
        )
    }

    static func from(_ reminder: Reminder) -> UniversalSearchResult {
        UniversalSearchResult(
            id: reminder.id,
            contentType: .reminder,
            title: reminder.title,
            subtitle: formatDate(reminder.reminderDate),
            snippet: nil,
            date: reminder.createdAt,
            isArchived: reminder.isTriggered,
            reminder: reminder
        )
    }

    static func from(_ bookmark: Bookmark) -> UniversalSearchResult {
        UniversalSearchResult(
            id: bookmark.id,
            contentType: .bookmark,
            title: bookmark.title,
            subtitle: bookmark.url,
            snippet: bookmark.description.isEmpty ? nil : String(bookmark.description.prefix(100)),
            date: bookmark.updatedAt,
            isArchived: bookmark.isRead,
            bookmark: bookmark
        )
    }

    static func from(_ meeting: Meeting) -> UniversalSearchResult {
        UniversalSearchResult(
            id: meeting.id,
            contentType: .meeting,
            title: meeting.title,
            subtitle: formatDate(meeting.meetingDate),
            snippet: meeting.overview.isEmpty ? nil : String(meeting.overview.prefix(100)),
            date: meeting.updatedAt,
            isArchived: false,
            meeting: meeting
        )
    }

    static func from(_ email: Email) -> UniversalSearchResult {
        UniversalSearchResult(
            id: email.id,
            contentType: .email,
            title: email.subject,
            subtitle: email.displaySender,
            snippet: email.snippet,
            date: email.receivedDate,
            isArchived: email.isRead,
            email: email
        )
    }

    static func from(_ event: CalendarEvent) -> UniversalSearchResult {
        UniversalSearchResult(
            id: event.id,
            contentType: .todo, // Calendar events show in todo view
            title: event.title,
            subtitle: event.formattedTimeRange,
            snippet: event.location,
            date: event.startTime,
            isArchived: event.isPast,
            calendarEvent: event
        )
    }

    static func from(_ connection: Connection) -> UniversalSearchResult {
        var subtitle = connection.headline
        if !connection.company.isEmpty {
            if !subtitle.isEmpty {
                subtitle += " @ "
            }
            subtitle += connection.company
        }

        return UniversalSearchResult(
            id: connection.id,
            contentType: .connection,
            title: connection.fullName,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            snippet: connection.notes.isEmpty ? nil : String(connection.notes.prefix(100)),
            date: connection.connectionDate ?? connection.importedAt,
            isArchived: false,
            connection: connection
        )
    }

    static func from(_ file: FileItem) -> UniversalSearchResult {
        UniversalSearchResult(
            id: file.id,
            contentType: .file,
            title: file.name,
            subtitle: "\(file.fileType.displayName) • \(file.formattedSize)",
            snippet: file.extractedText.map { String($0.prefix(100)) },
            date: file.updatedAt,
            isArchived: false,
            file: file
        )
    }

    static func from(_ xPost: XPost) -> UniversalSearchResult {
        UniversalSearchResult(
            id: xPost.id,
            contentType: .xPost,
            title: "@\(xPost.authorUsername)",
            subtitle: "\(xPost.likeCount) likes · \(xPost.retweetCount) reposts",
            snippet: xPost.text.isEmpty ? nil : String(xPost.text.prefix(100)),
            date: xPost.createdAt,
            isArchived: false,
            xPost: xPost
        )
    }

    static func from(_ xFollower: XFollower) -> UniversalSearchResult {
        UniversalSearchResult(
            id: xFollower.id,
            contentType: .xFollower,
            title: xFollower.displayName,
            subtitle: "@\(xFollower.username)",
            snippet: xFollower.bio.isEmpty ? nil : String(xFollower.bio.prefix(100)),
            date: xFollower.syncUpdatedAt,
            isArchived: false,
            xFollower: xFollower
        )
    }

    static func from(_ xDM: XDirectMessage) -> UniversalSearchResult {
        UniversalSearchResult(
            id: xDM.id,
            contentType: .xDm,
            title: xDM.senderDisplayName,
            subtitle: "@\(xDM.senderUsername)",
            snippet: xDM.text.isEmpty ? nil : String(xDM.text.prefix(100)),
            date: xDM.createdAt,
            isArchived: false,
            xDirectMessage: xDM
        )
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay == today {
            return "Today"
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return "Tomorrow"
        } else if dateDay == calendar.date(byAdding: .day, value: -1, to: today) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Search Options

struct SearchOptions {
    var includeContent: Bool = false
    var includeArchived: Bool = false
    var contentTypes: Set<ContentType> = Set(ContentType.allCases)
    var dateFilter: DateFilterOption = .anytime
    var customStartDate: Date?
    var customEndDate: Date?

    /// Returns the date range for the current filter option
    var dateRange: (start: Date, end: Date)? {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        switch dateFilter {
        case .anytime:
            return nil
        case .today:
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            return (startOfToday, endOfToday)
        case .yesterday:
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return (startOfYesterday, startOfToday)
        case .thisWeek:
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!
            return (weekStart, weekEnd)
        case .lastWeek:
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart)!
            return (lastWeekStart, thisWeekStart)
        case .thisMonth:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            return (monthStart, monthEnd)
        case .lastMonth:
            let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return (lastMonthStart, thisMonthStart)
        case .last7Days:
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
            return (weekAgo, now)
        case .last30Days:
            let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)!
            return (monthAgo, now)
        case .custom:
            if let start = customStartDate, let end = customEndDate {
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
                return (calendar.startOfDay(for: start), endOfDay)
            }
            return nil
        }
    }
}

/// Date filter options for search
enum DateFilterOption: String, CaseIterable {
    case anytime = "Anytime"
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case lastWeek = "Last Week"
    case thisMonth = "This Month"
    case lastMonth = "Last Month"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case custom = "Custom Range"
}
