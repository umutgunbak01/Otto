import Foundation

/// Parses natural language temporal expressions into date ranges
struct DateParser {
    /// Result of parsing a temporal expression
    struct DateRange {
        let startDate: Date
        let endDate: Date
        let description: String

        var contains: (Date) -> Bool {
            return { date in
                date >= startDate && date <= endDate
            }
        }
    }

    /// Parsed query with extracted date filters
    struct ParsedQuery {
        let originalQuery: String
        let cleanedQuery: String  // Query with temporal expressions removed
        let dateRange: DateRange?
        let contentTypes: Set<ContentType>?  // If user specifies "todos", "notes", etc.
    }

    private static let calendar = Calendar.current

    /// Parse a question and extract any temporal filters
    static func parse(_ query: String) -> ParsedQuery {
        let lowercased = query.lowercased()
        var dateRange: DateRange?
        var contentTypes: Set<ContentType>?
        var cleanedQuery = query

        // Extract content type filters
        contentTypes = extractContentTypes(from: lowercased)

        // Extract date range from temporal expressions
        dateRange = extractDateRange(from: lowercased)

        // Remove temporal expressions from query for cleaner text search
        cleanedQuery = removeTemporalExpressions(from: query)

        return ParsedQuery(
            originalQuery: query,
            cleanedQuery: cleanedQuery,
            dateRange: dateRange,
            contentTypes: contentTypes
        )
    }

    // MARK: - Content Type Extraction

    private static func extractContentTypes(from query: String) -> Set<ContentType>? {
        var types = Set<ContentType>()

        // Check for explicit content type mentions
        let todoPatterns = ["todo", "todos", "to-do", "to-dos", "task", "tasks", "action item", "action items"]
        let notePatterns = ["note", "notes"]
        let ideaPatterns = ["idea", "ideas"]
        let reminderPatterns = ["reminder", "reminders"]
        let bookmarkPatterns = ["bookmark", "bookmarks", "link", "links", "saved"]
        let meetingPatterns = ["meeting", "meetings", "call", "calls"]
        let emailPatterns = ["email", "emails", "mail", "mails", "message", "messages"]
        let connectionPatterns = ["connection", "connections", "contact", "contacts", "people", "person"]

        for pattern in todoPatterns where query.contains(pattern) {
            types.insert(.todo)
        }
        for pattern in notePatterns where query.contains(pattern) {
            types.insert(.note)
        }
        for pattern in ideaPatterns where query.contains(pattern) {
            types.insert(.idea)
        }
        for pattern in reminderPatterns where query.contains(pattern) {
            types.insert(.reminder)
        }
        for pattern in bookmarkPatterns where query.contains(pattern) {
            types.insert(.bookmark)
        }
        for pattern in meetingPatterns where query.contains(pattern) {
            types.insert(.meeting)
        }
        for pattern in emailPatterns where query.contains(pattern) {
            types.insert(.email)
        }
        for pattern in connectionPatterns where query.contains(pattern) {
            types.insert(.connection)
        }

        return types.isEmpty ? nil : types
    }

    // MARK: - Date Range Extraction

    private static func extractDateRange(from query: String) -> DateRange? {
        let now = Date()
        let today = calendar.startOfDay(for: now)

        // Today
        if query.contains("today") {
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: today)!.addingTimeInterval(-1)
            return DateRange(startDate: today, endDate: endOfDay, description: "today")
        }

        // Yesterday
        if query.contains("yesterday") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            let endOfYesterday = today.addingTimeInterval(-1)
            return DateRange(startDate: yesterday, endDate: endOfYesterday, description: "yesterday")
        }

        // Tomorrow
        if query.contains("tomorrow") {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!.addingTimeInterval(-1)
            return DateRange(startDate: tomorrow, endDate: endOfTomorrow, description: "tomorrow")
        }

        // This week
        if query.contains("this week") || query.contains("current week") {
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!.addingTimeInterval(-1)
            return DateRange(startDate: weekStart, endDate: weekEnd, description: "this week")
        }

        // Next week
        if query.contains("next week") {
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: thisWeekStart)!
            let nextWeekEnd = calendar.date(byAdding: .day, value: 14, to: thisWeekStart)!.addingTimeInterval(-1)
            return DateRange(startDate: nextWeekStart, endDate: nextWeekEnd, description: "next week")
        }

        // Last week
        if query.contains("last week") || query.contains("past week") {
            let thisWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart)!
            let lastWeekEnd = thisWeekStart.addingTimeInterval(-1)
            return DateRange(startDate: lastWeekStart, endDate: lastWeekEnd, description: "last week")
        }

        // This month
        if query.contains("this month") || query.contains("current month") {
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let monthEnd = nextMonth.addingTimeInterval(-1)
            return DateRange(startDate: monthStart, endDate: monthEnd, description: "this month")
        }

        // Next month
        if query.contains("next month") {
            let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: thisMonthStart)!
            let monthAfterNext = calendar.date(byAdding: .month, value: 2, to: thisMonthStart)!
            let nextMonthEnd = monthAfterNext.addingTimeInterval(-1)
            return DateRange(startDate: nextMonthStart, endDate: nextMonthEnd, description: "next month")
        }

        // Last month
        if query.contains("last month") || query.contains("past month") {
            let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)!
            let lastMonthEnd = thisMonthStart.addingTimeInterval(-1)
            return DateRange(startDate: lastMonthStart, endDate: lastMonthEnd, description: "last month")
        }

        // This year
        if query.contains("this year") || query.contains("current year") {
            let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now))!
            let nextYear = calendar.date(byAdding: .year, value: 1, to: yearStart)!
            let yearEnd = nextYear.addingTimeInterval(-1)
            return DateRange(startDate: yearStart, endDate: yearEnd, description: "this year")
        }

        // Last X days/weeks/months
        if let range = parseLastNTimeUnits(from: query) {
            return range
        }

        // Next X days/weeks/months
        if let range = parseNextNTimeUnits(from: query) {
            return range
        }

        // Specific day of week (e.g., "on Monday", "this Monday")
        if let range = parseWeekday(from: query) {
            return range
        }

        return nil
    }

    private static func parseLastNTimeUnits(from query: String) -> DateRange? {
        // Pattern: "last N days/weeks/months"
        let patterns = [
            ("last (\\d+) days?", Calendar.Component.day),
            ("past (\\d+) days?", Calendar.Component.day),
            ("last (\\d+) weeks?", Calendar.Component.weekOfYear),
            ("past (\\d+) weeks?", Calendar.Component.weekOfYear),
            ("last (\\d+) months?", Calendar.Component.month),
            ("past (\\d+) months?", Calendar.Component.month)
        ]

        for (pattern, component) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let numberRange = Range(match.range(at: 1), in: query),
               let number = Int(query[numberRange]) {

                let now = Date()
                let startDate = calendar.date(byAdding: component, value: -number, to: now)!
                return DateRange(startDate: startDate, endDate: now, description: "last \(number) \(component == .day ? "day(s)" : component == .weekOfYear ? "week(s)" : "month(s)")")
            }
        }

        return nil
    }

    private static func parseNextNTimeUnits(from query: String) -> DateRange? {
        // Pattern: "next N days/weeks/months"
        let patterns = [
            ("next (\\d+) days?", Calendar.Component.day),
            ("coming (\\d+) days?", Calendar.Component.day),
            ("next (\\d+) weeks?", Calendar.Component.weekOfYear),
            ("coming (\\d+) weeks?", Calendar.Component.weekOfYear),
            ("next (\\d+) months?", Calendar.Component.month),
            ("coming (\\d+) months?", Calendar.Component.month)
        ]

        for (pattern, component) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let numberRange = Range(match.range(at: 1), in: query),
               let number = Int(query[numberRange]) {

                let now = Date()
                let endDate = calendar.date(byAdding: component, value: number, to: now)!
                return DateRange(startDate: now, endDate: endDate, description: "next \(number) \(component == .day ? "day(s)" : component == .weekOfYear ? "week(s)" : "month(s)")")
            }
        }

        return nil
    }

    private static func parseWeekday(from query: String) -> DateRange? {
        let weekdays = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7)
        ]

        for (dayName, dayNumber) in weekdays {
            // Check for "this Monday", "on Monday", "monday"
            if query.contains(dayName) || query.contains("this \(dayName)") || query.contains("on \(dayName)") {
                let now = Date()
                let today = calendar.component(.weekday, from: now)

                var daysToAdd = dayNumber - today
                if daysToAdd < 0 {
                    daysToAdd += 7  // Move to next week if the day has passed
                }

                // If "next Monday" specifically, add a week
                if query.contains("next \(dayName)") {
                    daysToAdd += 7
                }

                let targetDay = calendar.date(byAdding: .day, value: daysToAdd, to: calendar.startOfDay(for: now))!
                let endOfTargetDay = calendar.date(byAdding: .day, value: 1, to: targetDay)!.addingTimeInterval(-1)

                return DateRange(startDate: targetDay, endDate: endOfTargetDay, description: dayName.capitalized)
            }
        }

        return nil
    }

    // MARK: - Query Cleaning

    private static func removeTemporalExpressions(from query: String) -> String {
        var cleaned = query

        // Remove common temporal phrases (case-insensitive)
        let temporalPhrases = [
            "this week", "next week", "last week", "past week", "current week",
            "this month", "next month", "last month", "past month", "current month",
            "this year", "next year", "last year", "current year",
            "today", "tomorrow", "yesterday",
            "this monday", "this tuesday", "this wednesday", "this thursday", "this friday", "this saturday", "this sunday",
            "next monday", "next tuesday", "next wednesday", "next thursday", "next friday", "next saturday", "next sunday",
            "on monday", "on tuesday", "on wednesday", "on thursday", "on friday", "on saturday", "on sunday",
            "for the week", "for this week", "for next week",
            "for the month", "for this month", "for next month",
            "due this week", "due next week", "due today", "due tomorrow"
        ]

        for phrase in temporalPhrases {
            if let range = cleaned.range(of: phrase, options: .caseInsensitive) {
                cleaned.replaceSubrange(range, with: "")
            }
        }

        // Remove "last N days/weeks/months" patterns
        let lastNPatterns = [
            "last \\d+ days?", "past \\d+ days?",
            "last \\d+ weeks?", "past \\d+ weeks?",
            "last \\d+ months?", "past \\d+ months?",
            "next \\d+ days?", "coming \\d+ days?",
            "next \\d+ weeks?", "coming \\d+ weeks?",
            "next \\d+ months?", "coming \\d+ months?"
        ]

        for pattern in lastNPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }

        // Clean up extra whitespace
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}
