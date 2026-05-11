import SwiftUI

struct Habit: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var notes: String
    var iconName: String
    var colorTag: ColorTag
    var category: Category
    var kind: Kind
    var unit: String?
    var dailyTarget: Double
    var frequency: Frequency
    var entries: [HabitEntry]
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Nested types

    enum Kind: String, Codable, CaseIterable, Hashable {
        case binary, quantity, duration, count

        var displayName: String {
            switch self {
            case .binary:   return "Done / Not Done"
            case .quantity: return "Quantity"
            case .duration: return "Duration"
            case .count:    return "Count"
            }
        }
    }

    enum Category: String, Codable, CaseIterable, Hashable {
        case health, fitness, learning, mindfulness, personalCare, nutrition, productivity, custom

        var displayName: String {
            switch self {
            case .health:        return "Health"
            case .fitness:       return "Fitness"
            case .learning:      return "Learning"
            case .mindfulness:   return "Mindfulness"
            case .personalCare:  return "Personal Care"
            case .nutrition:     return "Nutrition"
            case .productivity:  return "Productivity"
            case .custom:        return "Custom"
            }
        }
    }

    enum ColorTag: String, Codable, CaseIterable, Hashable {
        case cyan, green, amber, red, aiAccent, cyanDim, hobby

        var color: Color {
            switch self {
            case .cyan:     return Theme.Colors.cyan
            case .green:    return Theme.Colors.green
            case .amber:    return Theme.Colors.amber
            case .red:      return Theme.Colors.red
            case .aiAccent: return Theme.Colors.aiAccent
            case .cyanDim:  return Theme.Colors.cyanDim
            case .hobby:    return Theme.Colors.hobby
            }
        }
    }

    enum Weekday: Int, Codable, CaseIterable, Hashable {
        case sun = 1, mon, tue, wed, thu, fri, sat

        var shortName: String {
            switch self {
            case .sun: return "Sun"; case .mon: return "Mon"; case .tue: return "Tue"
            case .wed: return "Wed"; case .thu: return "Thu"; case .fri: return "Fri"
            case .sat: return "Sat"
            }
        }
    }

    enum Frequency: Codable, Hashable {
        case daily
        case weekdays(Set<Weekday>)
        case weeklyCount(Int)

        var displayName: String {
            switch self {
            case .daily: return "Daily"
            case .weekdays(let days):
                let ordered: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
                let labels = ordered.filter { days.contains($0) }.map { $0.shortName }
                return labels.isEmpty ? "Daily" : labels.joined(separator: " · ")
            case .weeklyCount(let n):
                return "\(n)× / week"
            }
        }

        // Manual Codable so we get a clean discriminated JSON shape.
        private enum CodingKeys: String, CodingKey { case kind, weekdays, count }
        private enum Tag: String, Codable { case daily, weekdays, weeklyCount }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .daily:
                try c.encode(Tag.daily, forKey: .kind)
            case .weekdays(let days):
                try c.encode(Tag.weekdays, forKey: .kind)
                try c.encode(days.sorted { $0.rawValue < $1.rawValue }, forKey: .weekdays)
            case .weeklyCount(let n):
                try c.encode(Tag.weeklyCount, forKey: .kind)
                try c.encode(n, forKey: .count)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try c.decode(Tag.self, forKey: .kind)
            switch tag {
            case .daily:
                self = .daily
            case .weekdays:
                let days = (try? c.decode([Weekday].self, forKey: .weekdays)) ?? []
                self = .weekdays(Set(days))
            case .weeklyCount:
                let n = (try? c.decode(Int.self, forKey: .count)) ?? 1
                self = .weeklyCount(max(1, n))
            }
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        iconName: String = "checkmark.circle",
        colorTag: ColorTag = .cyan,
        category: Category = .custom,
        kind: Kind = .binary,
        unit: String? = nil,
        dailyTarget: Double = 1,
        frequency: Frequency = .daily,
        entries: [HabitEntry] = [],
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.iconName = iconName
        self.colorTag = colorTag
        self.category = category
        self.kind = kind
        self.unit = unit
        self.dailyTarget = dailyTarget
        self.frequency = frequency
        self.entries = entries
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable (forward-compatible decoding)

    enum CodingKeys: String, CodingKey {
        case id, title, notes, iconName, colorTag, category, kind, unit
        case dailyTarget, frequency, entries, isArchived, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        iconName = (try? c.decode(String.self, forKey: .iconName)) ?? "checkmark.circle"
        colorTag = (try? c.decode(ColorTag.self, forKey: .colorTag)) ?? .cyan
        category = (try? c.decode(Category.self, forKey: .category)) ?? .custom
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .binary
        unit = try? c.decode(String.self, forKey: .unit)
        dailyTarget = (try? c.decode(Double.self, forKey: .dailyTarget)) ?? 1
        frequency = (try? c.decode(Frequency.self, forKey: .frequency)) ?? .daily
        entries = (try? c.decode([HabitEntry].self, forKey: .entries)) ?? []
        isArchived = (try? c.decode(Bool.self, forKey: .isArchived)) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Habit Entry

struct HabitEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var date: Date
    var value: Double
    var note: String?

    init(id: UUID = UUID(), date: Date = Date(), value: Double = 1, note: String? = nil) {
        self.id = id
        self.date = date
        self.value = value
        self.note = note
    }
}

// MARK: - Stats / queries

extension Habit {
    /// Whether this habit is "required" on the given day, given its frequency.
    /// Used for streak math and the today-score header.
    func isRequired(on date: Date, calendar: Calendar = .current) -> Bool {
        switch frequency {
        case .daily:
            return true
        case .weekdays(let days):
            guard !days.isEmpty else { return true }
            let weekday = calendar.component(.weekday, from: date) // 1 = Sun
            return days.contains(where: { $0.rawValue == weekday })
        case .weeklyCount:
            // Any day counts as required for weeklyCount habits — the goal
            // is N over the week, so progress tracks the current week.
            return true
        }
    }

    /// Total logged value for the calendar day containing `date`.
    func progress(on date: Date, calendar: Calendar = .current) -> Double {
        let day = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return entries
            .filter { $0.date >= day && $0.date < next }
            .reduce(0) { $0 + $1.value }
    }

    /// For weeklyCount, count the number of days this week that hit `dailyTarget`.
    /// For other frequencies, returns 1 if today's progress meets target, else 0.
    func weeklyProgress(asOf date: Date = Date(), calendar: Calendar = .current) -> Int {
        guard case .weeklyCount = frequency else {
            return isMet(on: date, calendar: calendar) ? 1 : 0
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        var count = 0
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
                  day <= date else { break }
            if progress(on: day, calendar: calendar) >= max(1, dailyTarget) {
                count += 1
            }
        }
        return count
    }

    /// Whether the day's target has been met. For binary, "any entry today".
    func isMet(on date: Date, calendar: Calendar = .current) -> Bool {
        let target = max(1, dailyTarget)
        switch kind {
        case .binary:
            return progress(on: date, calendar: calendar) >= 1
        default:
            return progress(on: date, calendar: calendar) >= target
        }
    }

    /// Days of consecutive met-required-days ending at `today`. Skips
    /// non-required days (so a M/W/F habit isn't broken by Tuesday).
    func currentStreak(asOf today: Date = Date(), calendar: Calendar = .current) -> Int {
        var streak = 0
        var cursor = calendar.startOfDay(for: today)
        // Don't penalize for "today" not being met yet — only break the streak
        // once we've passed a required day that wasn't met.
        if isRequired(on: cursor, calendar: calendar), !isMet(on: cursor, calendar: calendar) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while true {
            if isRequired(on: cursor, calendar: calendar) {
                if isMet(on: cursor, calendar: calendar) {
                    streak += 1
                } else {
                    break
                }
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            // Stop walking back past the habit's creation day.
            if prev < calendar.startOfDay(for: createdAt) { break }
            cursor = prev
        }
        return streak
    }

    /// Longest streak ever (walks every day from createdAt to today).
    func longestStreak(asOf today: Date = Date(), calendar: Calendar = .current) -> Int {
        var best = 0
        var run = 0
        var cursor = calendar.startOfDay(for: createdAt)
        let end = calendar.startOfDay(for: today)
        while cursor <= end {
            if isRequired(on: cursor, calendar: calendar) {
                if isMet(on: cursor, calendar: calendar) {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return best
    }

    /// Met-days / required-days over the last N days (inclusive of today).
    func completionRate(lastDays: Int, asOf today: Date = Date(), calendar: Calendar = .current) -> Double {
        var met = 0
        var required = 0
        let end = calendar.startOfDay(for: today)
        for offset in 0..<lastDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            if day < calendar.startOfDay(for: createdAt) { continue }
            if isRequired(on: day, calendar: calendar) {
                required += 1
                if isMet(on: day, calendar: calendar) { met += 1 }
            }
        }
        guard required > 0 else { return 0 }
        return Double(met) / Double(required)
    }

    /// Total of all entry values, all-time. Useful for "you've read 4,200 pages".
    var totalAllTime: Double {
        entries.reduce(0) { $0 + $1.value }
    }
}
