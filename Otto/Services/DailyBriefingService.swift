import Foundation
import Observation

// MARK: - Model

/// One generated daily briefing — the agent-written summary rendered in the
/// Home right rail. Cached in UserDefaults and regenerated once per day (or
/// on manual refresh).
struct DailyBriefing: Codable, Equatable {
    struct EventItem: Codable, Equatable, Hashable {
        var time: String
        var title: String
        var note: String
        var location: String?

        init(time: String = "", title: String = "", note: String = "", location: String? = nil) {
            self.time = time; self.title = title; self.note = note; self.location = location
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = (try? c.decode(String.self, forKey: .time)) ?? ""
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            note = (try? c.decode(String.self, forKey: .note)) ?? ""
            location = try? c.decode(String.self, forKey: .location)
        }
    }

    struct TodoItem: Codable, Equatable, Hashable {
        var title: String
        var note: String?
        var urgency: String?   // "high" | "normal"

        init(title: String = "", note: String? = nil, urgency: String? = nil) {
            self.title = title; self.note = note; self.urgency = urgency
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            note = try? c.decode(String.self, forKey: .note)
            urgency = try? c.decode(String.self, forKey: .urgency)
        }

        var isHighUrgency: Bool { urgency?.lowercased() == "high" }
    }

    var generatedAt: Date
    var headline: String
    var summary: String
    var events: [EventItem]
    var todos: [TodoItem]
    var headsUp: [String]
}

// MARK: - Service

/// Generates and caches the agent-written daily briefing.
///
/// Generation is a one-shot agent run with Otto's MCP tools available so the
/// model can look up context (past meetings with today's attendees, related
/// notes/emails) before writing. It runs on the same backend the user picked
/// for chat (`AgentBackend.current`) under its own `sessionKey`, so it's
/// fully isolated from chat conversations and can run alongside them.
@MainActor
@Observable
final class DailyBriefingService {
    static let shared = DailyBriefingService()

    private(set) var briefing: DailyBriefing?
    private(set) var isGenerating = false
    /// Last generation failure, shown in the panel footer. Cleared on retry.
    private(set) var lastError: String?

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    /// Isolates briefing runs from chat conversations on the shared backends
    /// (own subprocess slot on the CLI backends, own ACP session on Hermes).
    @ObservationIgnored private let briefingSessionKey = UUID()

    private static let cacheKey = "dailyBriefing.cache.v1"

    private init() {
        briefing = Self.loadCache()
    }

    // MARK: - Public API

    /// True when there's no briefing for today yet.
    var isStale: Bool {
        guard let briefing else { return true }
        return !Calendar.current.isDateInToday(briefing.generatedAt)
    }

    var canGenerate: Bool { pickBackend() != nil }

    /// Auto path — called when the panel appears. Regenerates only if
    /// today's briefing doesn't exist yet.
    func ensureFresh(appState: AppState) {
        guard isStale else { return }
        start(appState: appState)
    }

    /// Manual refresh button.
    func refresh(appState: AppState) {
        start(appState: appState)
    }

    // MARK: - Generation

    private func start(appState: AppState) {
        guard !isGenerating else { return }
        guard let backend = pickBackend() else {
            lastError = "No agent backend signed in."
            return
        }

        isGenerating = true
        lastError = nil

        let userPrompt = Self.userPrompt(appState: appState)
        let systemPrompt = Self.briefingSystemPrompt

        let sessionKey = briefingSessionKey
        generationTask = Task { [weak self] in
            defer {
                if let self, !Task.isCancelled {
                    self.isGenerating = false
                }
            }
            do {
                let executor = OttoToolExecutor(appState: appState)
                let turns = [ChatTurn(role: "user", blocks: [.text(userPrompt)])]
                let result = try await Self.run(
                    backend: backend,
                    sessionKey: sessionKey,
                    turns: turns,
                    systemPrompt: systemPrompt,
                    executor: executor
                )
                if Task.isCancelled { return }
                let text = Self.finalAssistantText(result)
                let fresh = try Self.parseBriefing(text)
                self?.briefing = fresh
                Self.saveCache(fresh)
            } catch {
                if Task.isCancelled { return }
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// The briefing runs on whatever backend the user selected for chat,
    /// provided it's actually usable (signed in / installed).
    private func pickBackend() -> AgentBackend? {
        switch AgentBackend.current {
        case .claude:
            return ClaudeAuthService.shared.effectiveAuthMode() != .none ? .claude : nil
        case .codex:
            return CodexAuthService.shared.effectiveAuthMode() != .none ? .codex : nil
        case .hermes:
            return HermesInstallation.binaryPath() != nil ? .hermes : nil
        }
    }

    private static func run(
        backend: AgentBackend,
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        executor: OttoToolExecutor
    ) async throws -> [ChatTurn] {
        switch backend {
        case .claude:
            return try await ClaudeCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .codex:
            return try await CodexCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .hermes:
            return try await HermesAgentService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        }
    }

    // MARK: - Prompts

    private static let briefingSystemPrompt = """
    You are Otto's daily-briefing writer. Produce today's briefing for the user's home panel.

    You have Otto's MCP tools. Use ONLY the read tools — semantic_search, search_items, grep_data, get_item, list_habits, read_file. Do NOT create, update, complete, or delete anything during this task.

    Investigate before you write. For each upcoming calendar event, look up the attendees and their companies (search_items with type network / connection / company, or grep_data on network_hub.csv / companies.csv) and what happened last (search_items across meeting / email / note with their name or company). A good event note reads like "Last met Jun 12 — discussed pricing; they owed you the data-room link" or "First meeting — VC intro via Arın". Keep each note to 1–2 short sentences, concrete and useful for prep. Never invent facts: if you find nothing, omit the note or say "no prior history".

    Reply with STRICT JSON only — no markdown fences, no prose before or after the JSON object. Schema:
    {
      "headline": "one line, ≤60 chars, naming the day's center of gravity",
      "summary": "2–3 sentences narrating the day: what matters most, what to prep, what can slip",
      "events": [{ "time": "09:30" or "Tomorrow 14:00" or "All day", "title": "...", "note": "prep/context from your lookups", "location": "..." }],
      "todos": [{ "title": "...", "note": "why it matters today", "urgency": "high" or "normal" }],
      "heads_up": ["overdue work, waiting-on replies, an important unread email, a habit streak at risk, a relationship follow-up that's overdue (from the Follow-ups due section — name the person)"]
    }

    Limits: events ≤5 (today and tomorrow only; [] if none), todos ≤6 (only the ones that actually matter today), heads_up ≤4. All values are plain text — no markdown, no otto:// links.
    """

    /// The user turn: date header plus a deterministic seed of today's data so
    /// the agent starts from facts and spends its tool calls on enrichment.
    private static func userPrompt(appState: AppState) -> String {
        var out = "Generate my daily briefing.\n\n"
        out += seedContext(appState: appState)
        return out
    }

    private static func seedContext(appState: AppState) -> String {
        let now = Date()
        let cal = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        var lines: [String] = []
        lines.append("Today is \(headerFormatter.string(from: now)), local time \(timeFormatter.string(from: now)) (\(TimeZone.current.identifier)).")
        lines.append("")

        // Calendar — next 7 days.
        let horizon = cal.date(byAdding: .day, value: 7, to: now) ?? now
        let events = appState.calendarEvents
            .filter { $0.endTime > now && $0.startTime < horizon }
            .sorted { $0.startTime < $1.startTime }
            .prefix(12)
        lines.append("## Calendar (next 7 days)")
        if events.isEmpty {
            lines.append("No calendar events in the next 7 days.")
        } else {
            for e in events {
                var line = "- \(dayFormatter.string(from: e.startTime)) "
                line += e.isAllDay ? "all day" : "\(timeFormatter.string(from: e.startTime))–\(timeFormatter.string(from: e.endTime))"
                line += " — \(e.title)"
                if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
                if !e.attendees.isEmpty { line += " [attendees: \(e.attendees.prefix(6).joined(separator: ", "))]" }
                lines.append(line)
            }
        }
        lines.append("")

        // To-dos — overdue and due-today first, then urgent/high, capped.
        let open = appState.todos.filter { !$0.isCompleted }
        func rank(_ t: Todo) -> Int {
            if let due = t.dueDate, due < now { return 0 }
            if let due = t.dueDate, cal.isDateInToday(due) { return 1 }
            if t.priority == .urgent { return 2 }
            if t.priority == .high { return 3 }
            return 4
        }
        let todos = open.sorted {
            let (ra, rb) = (rank($0), rank($1))
            if ra != rb { return ra < rb }
            return $0.updatedAt > $1.updatedAt
        }.prefix(15)
        lines.append("## Open to-dos")
        if todos.isEmpty {
            lines.append("No open to-dos.")
        } else {
            for t in todos {
                var line = "- [\(t.priority.displayName.lowercased())] \(t.title)"
                if let due = t.dueDate {
                    line += due < now ? " — OVERDUE (was due \(dayFormatter.string(from: due)))"
                                      : " — due \(dayFormatter.string(from: due))"
                }
                lines.append(line)
            }
        }
        lines.append("")

        // Recent meetings — context anchors for lookups.
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let meetings = appState.meetings
            .filter { $0.meetingDate > weekAgo }
            .sorted { $0.meetingDate > $1.meetingDate }
            .prefix(6)
        lines.append("## Recent meetings (last 7 days)")
        if meetings.isEmpty {
            lines.append("None.")
        } else {
            for m in meetings {
                var line = "- \(dayFormatter.string(from: m.meetingDate)) — \(m.title)"
                if !m.participants.isEmpty { line += " (\(m.participants.prefix(4).joined(separator: ", ")))" }
                lines.append(line)
            }
        }
        lines.append("")

        // Inbox.
        let unread = appState.emails.filter { !$0.isRead }
        if EmailTriageSettings.isEnabled {
            let queue = EmailTriageService.needsReply(emails: appState.emails, blockedSenders: appState.blockedSenders)
            lines.append("## Inbox — needs reply (\(queue.count) threads waiting on the user)")
            for e in queue.prefix(4) {
                lines.append("- \"\(e.subject)\" from \(e.displaySender) (\(dayFormatter.string(from: e.receivedDate)))")
            }
        } else {
            lines.append("## Inbox")
            lines.append("\(unread.count) unread.")
            for e in unread.sorted(by: { $0.receivedDate > $1.receivedDate }).prefix(3) {
                lines.append("- \"\(e.subject)\" from \(e.displaySender) (\(dayFormatter.string(from: e.receivedDate)))")
            }
        }

        // Keep-in-touch queue — relationships whose follow-up cadence lapsed.
        let dueFollowUps = appState.networkEntries
            .compactMap { entry in entry.followUpOverdueDays().map { (entry, $0) } }
            .sorted { $0.1 > $1.1 }
        if !dueFollowUps.isEmpty {
            lines.append("")
            lines.append("## Follow-ups due (keep in touch)")
            for (entry, days) in dueFollowUps.prefix(5) {
                let who = [entry.name, entry.displayInfo].filter { !$0.isEmpty }.joined(separator: " — ")
                let overdue = days == 0 ? "due today" : "\(days)d overdue"
                lines.append("- \(who): \(overdue)")
            }
            if dueFollowUps.count > 5 {
                lines.append("- …and \(dueFollowUps.count - 5) more")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Output parsing

    private static func finalAssistantText(_ turns: [ChatTurn]) -> String {
        guard let last = turns.last(where: { $0.role == "assistant" }) else { return "" }
        return last.blocks.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    private struct Payload: Decodable {
        var headline = ""
        var summary = ""
        var events: [DailyBriefing.EventItem] = []
        var todos: [DailyBriefing.TodoItem] = []
        var headsUp: [String] = []

        enum CodingKeys: String, CodingKey {
            case headline, summary, events, todos
            case headsUp = "heads_up"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
            summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
            events = (try? c.decode([DailyBriefing.EventItem].self, forKey: .events)) ?? []
            todos = (try? c.decode([DailyBriefing.TodoItem].self, forKey: .todos)) ?? []
            headsUp = (try? c.decode([String].self, forKey: .headsUp)) ?? []
        }
    }

    enum BriefingError: LocalizedError {
        case emptyReply
        case unparseable

        var errorDescription: String? {
            switch self {
            case .emptyReply:  return "The agent returned an empty reply."
            case .unparseable: return "Couldn't parse the briefing reply."
            }
        }
    }

    /// Slice the reply down to its outermost JSON object (models occasionally
    /// wrap output in ``` fences or lead with a sentence despite instructions)
    /// and decode leniently.
    private static func parseBriefing(_ text: String) throws -> DailyBriefing {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BriefingError.emptyReply }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw BriefingError.unparseable }

        let briefing = DailyBriefing(
            generatedAt: Date(),
            headline: payload.headline,
            summary: payload.summary,
            events: payload.events.filter { !$0.title.isEmpty },
            todos: payload.todos.filter { !$0.title.isEmpty },
            headsUp: payload.headsUp.filter { !$0.isEmpty }
        )
        guard !briefing.headline.isEmpty || !briefing.summary.isEmpty
                || !briefing.events.isEmpty || !briefing.todos.isEmpty else {
            throw BriefingError.unparseable
        }
        return briefing
    }

    // MARK: - Cache

    private static func loadCache() -> DailyBriefing? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DailyBriefing.self, from: data)
    }

    private static func saveCache(_ briefing: DailyBriefing) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(briefing) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
