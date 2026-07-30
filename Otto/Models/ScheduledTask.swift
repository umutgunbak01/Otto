import Foundation

// MARK: - Schedule

/// When a recurring task fires: a day rule plus a local wall-clock time.
/// Occurrence math is calendar-based (`Calendar.nextDate`) so DST transitions
/// resolve to the next valid wall time instead of drifting by an hour.
struct TaskSchedule: Codable, Hashable {
    /// Which days the task runs. Weekday sets reuse `Habit.Weekday`
    /// (rawValue 1–7 == `Calendar` weekday numbering, Sunday = 1).
    enum Days: Codable, Hashable {
        case daily
        case weekdays(Set<Habit.Weekday>)
        case monthly(day: Int)

        // Manual Codable so we get a clean discriminated JSON shape,
        // mirroring Habit.Frequency.
        private enum CodingKeys: String, CodingKey { case kind, weekdays, day }
        private enum Tag: String, Codable { case daily, weekdays, monthly }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .daily:
                try c.encode(Tag.daily, forKey: .kind)
            case .weekdays(let days):
                try c.encode(Tag.weekdays, forKey: .kind)
                try c.encode(days.sorted { $0.rawValue < $1.rawValue }, forKey: .weekdays)
            case .monthly(let day):
                try c.encode(Tag.monthly, forKey: .kind)
                try c.encode(day, forKey: .day)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try c.decode(Tag.self, forKey: .kind)
            switch tag {
            case .daily:
                self = .daily
            case .weekdays:
                let days = (try? c.decode([Habit.Weekday].self, forKey: .weekdays)) ?? []
                self = days.isEmpty ? .daily : .weekdays(Set(days))
            case .monthly:
                let day = (try? c.decode(Int.self, forKey: .day)) ?? 1
                self = .monthly(day: min(max(day, 1), 31))
            }
        }
    }

    var days: Days
    var hour: Int    // 0–23, user-local
    var minute: Int  // 0–59

    init(days: Days = .daily, hour: Int = 9, minute: Int = 0) {
        self.days = days
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    private enum CodingKeys: String, CodingKey { case days, hour, minute }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let days = (try? c.decode(Days.self, forKey: .days)) ?? .daily
        let hour = (try? c.decode(Int.self, forKey: .hour)) ?? 9
        let minute = (try? c.decode(Int.self, forKey: .minute)) ?? 0
        self.init(days: days, hour: hour, minute: minute)
    }

    // MARK: Occurrence math

    /// The next scheduled wall-clock occurrence strictly after `after`.
    func nextOccurrence(after: Date, calendar: Calendar = .current) -> Date {
        let fallback = after.addingTimeInterval(24 * 3600)
        switch days {
        case .daily:
            let comps = DateComponents(hour: hour, minute: minute)
            return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime) ?? fallback

        case .weekdays(let set):
            guard !set.isEmpty else {
                let comps = DateComponents(hour: hour, minute: minute)
                return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime) ?? fallback
            }
            let candidates = set.compactMap { day -> Date? in
                let comps = DateComponents(hour: hour, minute: minute, weekday: day.rawValue)
                return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime)
            }
            return candidates.min() ?? fallback

        case .monthly(let day):
            // `Calendar.nextDate(matching: day)` skips months without that day
            // (the 31st would jump Feb→Mar), so scan months and clamp instead:
            // "monthly on the 31st" means the last day of shorter months.
            let target = min(max(day, 1), 31)
            var monthComps = calendar.dateComponents([.year, .month], from: after)
            monthComps.day = 1
            guard var monthStart = calendar.date(from: monthComps) else { return fallback }
            for _ in 0..<24 {
                if let dayRange = calendar.range(of: .day, in: .month, for: monthStart) {
                    var c = calendar.dateComponents([.year, .month], from: monthStart)
                    c.day = min(target, dayRange.count)
                    c.hour = hour
                    c.minute = minute
                    if let candidate = calendar.date(from: c), candidate > after {
                        return candidate
                    }
                }
                monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
                    ?? monthStart.addingTimeInterval(32 * 24 * 3600)
            }
            return fallback
        }
    }

    // MARK: Display

    /// "Daily · 09:00", "Weekdays · 09:00", "Mon · Wed · 14:30",
    /// "Monthly (15th) · 08:00" — for list rows and tool output.
    var displaySummary: String {
        "\(daysSummary) · \(timeSummary)"
    }

    var timeSummary: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var daysSummary: String {
        switch days {
        case .daily:
            return "Daily"
        case .weekdays(let set):
            let workweek: Set<Habit.Weekday> = [.mon, .tue, .wed, .thu, .fri]
            if set == workweek { return "Weekdays" }
            if set.count == 7 { return "Daily" }
            let ordered: [Habit.Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
            let labels = ordered.filter { set.contains($0) }.map(\.shortName)
            return labels.isEmpty ? "Daily" : labels.joined(separator: " · ")
        case .monthly(let day):
            return "Monthly (\(Self.ordinal(day)))"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1):       suffix = "st"
        case (_, 2):       suffix = "nd"
        case (_, 3):       suffix = "rd"
        default:           suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

// MARK: - Run record

/// One execution of a recurring task — kept (capped) on the task so the
/// Automations tab can show history and deep-link into the chat session the
/// run produced.
struct TaskRunRecord: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case running
        case succeeded
        case failed
        /// The app quit mid-run; the session keeps its checkpointed partial
        /// transcript but the run never reported completion.
        case interrupted

        var displayName: String {
            switch self {
            case .running:     return "Running"
            case .succeeded:   return "Done"
            case .failed:      return "Failed"
            case .interrupted: return "Interrupted"
            }
        }
    }

    let id: UUID
    /// The occurrence this run satisfies — differs from `startedAt` when the
    /// run is an anacron-style catch-up ("ran 1h late").
    var scheduledFor: Date
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var chatSessionId: UUID?
    var errorMessage: String?
    var wasManual: Bool

    init(
        id: UUID = UUID(),
        scheduledFor: Date,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: Status = .running,
        chatSessionId: UUID? = nil,
        errorMessage: String? = nil,
        wasManual: Bool = false
    ) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.chatSessionId = chatSessionId
        self.errorMessage = errorMessage
        self.wasManual = wasManual
    }

    private enum CodingKeys: String, CodingKey {
        case id, scheduledFor, startedAt, finishedAt, status, chatSessionId, errorMessage, wasManual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scheduledFor = try c.decode(Date.self, forKey: .scheduledFor)
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? scheduledFor
        finishedAt = try? c.decode(Date.self, forKey: .finishedAt)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .interrupted
        chatSessionId = try? c.decode(UUID.self, forKey: .chatSessionId)
        errorMessage = try? c.decode(String.self, forKey: .errorMessage)
        wasManual = (try? c.decode(Bool.self, forKey: .wasManual)) ?? false
    }
}

// MARK: - Scheduled task

/// A recurring agent task: a prompt plus a schedule. The scheduler is
/// anacron-style — Otto only runs while the app is open, so a missed 9:00
/// fire happens at the first opportunity after (launch, wake, next tick),
/// at most once per calendar day.
struct ScheduledTask: Identifiable, Codable, Hashable {
    /// What to do when the app wasn't running at fire time.
    enum CatchUpPolicy: String, Codable, CaseIterable {
        /// Run at the first opportunity, even hours or days late (default).
        case runASAP
        /// Only run on the scheduled day; if that whole day passed, wait for
        /// the next scheduled occurrence. For tasks that only make sense at
        /// their time ("at 18:00 summarize my day").
        case skipToNext

        var displayName: String {
            switch self {
            case .runASAP:    return "Run as soon as possible"
            case .skipToNext: return "Skip to next scheduled time"
            }
        }
    }

    static let maxRunRecords = 20

    let id: UUID
    var name: String
    var prompt: String
    var schedule: TaskSchedule
    var isEnabled: Bool
    var catchUpPolicy: CatchUpPolicy
    var notifyOnCompletion: Bool
    /// Approve every tool permission request automatically during this
    /// task's runs (registered with `ToolApprovalPolicy` for the run's
    /// duration). Keeps unattended runs from stalling on an approval card —
    /// today that's the Hermes backend's `session/request_permission`.
    var autoApproveTools: Bool
    /// The next occurrence this task should satisfy. Persisted so a relaunch
    /// knows what was missed. Recomputed on edit/toggle and after each run.
    var nextDueAt: Date?
    /// When the last *scheduled* run started (manual runs don't touch this —
    /// it drives the once-per-day catch-up guard).
    var lastRunAt: Date?
    var runs: [TaskRunRecord]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        schedule: TaskSchedule = TaskSchedule(),
        isEnabled: Bool = true,
        catchUpPolicy: CatchUpPolicy = .runASAP,
        notifyOnCompletion: Bool = true,
        autoApproveTools: Bool = false,
        nextDueAt: Date? = nil,
        lastRunAt: Date? = nil,
        runs: [TaskRunRecord] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.catchUpPolicy = catchUpPolicy
        self.notifyOnCompletion = notifyOnCompletion
        self.autoApproveTools = autoApproveTools
        self.nextDueAt = nextDueAt
        self.lastRunAt = lastRunAt
        self.runs = runs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, schedule, isEnabled, catchUpPolicy, notifyOnCompletion
        case autoApproveTools
        case nextDueAt, lastRunAt, runs, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        schedule = (try? c.decode(TaskSchedule.self, forKey: .schedule)) ?? TaskSchedule()
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        catchUpPolicy = (try? c.decode(CatchUpPolicy.self, forKey: .catchUpPolicy)) ?? .runASAP
        notifyOnCompletion = (try? c.decode(Bool.self, forKey: .notifyOnCompletion)) ?? true
        autoApproveTools = (try? c.decode(Bool.self, forKey: .autoApproveTools)) ?? false
        nextDueAt = try? c.decode(Date.self, forKey: .nextDueAt)
        lastRunAt = try? c.decode(Date.self, forKey: .lastRunAt)
        runs = (try? c.decode([TaskRunRecord].self, forKey: .runs)) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }

    /// Newest-first insert, capped at `maxRunRecords`.
    mutating func appendRun(_ record: TaskRunRecord) {
        runs.insert(record, at: 0)
        if runs.count > Self.maxRunRecords {
            runs = Array(runs.prefix(Self.maxRunRecords))
        }
    }

    var latestRun: TaskRunRecord? { runs.first }
}
