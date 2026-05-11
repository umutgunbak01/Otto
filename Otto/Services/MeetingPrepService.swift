import Foundation

/// Background worker that compiles a 3-sentence attendee brief for upcoming
/// calendar events and schedules a system notification 10 min before each one.
///
/// Polling loop runs every 2 min while `start()` is active. For every event
/// starting within the next 60 min that hasn't been prepped yet:
///   1. Locally assemble context about each attendee (Gmail, Fireflies,
///      LinkedIn Connection record).
///   2. Ask Claude (via the CLI backend) to synthesize a spoken-friendly brief.
///      Tools aren't needed — all context is pre-gathered.
///   3. Save the answer as a Note titled `Prep: <meeting title>`.
///   4. Schedule a UNUserNotification at `startTime - 10 min` carrying the
///      note's id, so tapping it opens the prep Note in the Notes tab.
///   5. Remember the `googleEventId` in UserDefaults to avoid re-prepping.
///
/// Failure modes are swallowed and logged — a flaky API call during prep
/// shouldn't crash or block the app.
///
/// Not `@MainActor`-annotated so `AppState.init` can instantiate it as a
/// stored property. All methods that touch AppState or UI state hop to main
/// via `Task { @MainActor in ... }`; the class is safe to hold concurrently
/// thanks to `@unchecked Sendable`.
final class MeetingPrepService: @unchecked Sendable {

    // MARK: - Tunables

    /// How often to re-scan calendarEvents for prep candidates.
    private let pollInterval: TimeInterval = 120
    /// Event must start within this many seconds to be considered for prep.
    /// 60 min gives enough runway to catch late-opened apps and still fire
    /// the 10-min-before notification.
    private let lookaheadWindow: TimeInterval = 60 * 60
    /// How far before `startTime` to fire the notification.
    private let notifyLead: TimeInterval = 10 * 60
    /// Cap on items per data source stuffed into the prompt — keeps the
    /// context window reasonable.
    private let maxItemsPerSource: Int = 5

    // MARK: - Dependencies

    private weak var appState: AppState?
    private let claudeCLI = ClaudeCLIService.shared
    private let notifications = NotificationService.shared

    // MARK: - State

    private var timer: Timer?
    private var inFlightEventIds: Set<String> = []

    // UserDefaults-backed set of event ids we've already prepped.
    private static let preppedKey = "meetingPrep.preppedEventIds"

    private var preppedEventIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.preppedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.preppedKey) }
    }

    // MARK: - Lifecycle

    func configure(appState: AppState) {
        self.appState = appState
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Kick off one pass immediately so newly-opened apps don't wait 2 min.
        Task { @MainActor in await self.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll tick

    private func tick() async {
        guard let appState = appState else { return }
        let now = Date()
        let windowEnd = now.addingTimeInterval(lookaheadWindow)

        let candidates = appState.calendarEvents.filter { event in
            event.startTime > now &&
            event.startTime <= windowEnd &&
            !preppedEventIds.contains(event.googleEventId) &&
            !inFlightEventIds.contains(event.googleEventId)
        }

        for event in candidates {
            inFlightEventIds.insert(event.googleEventId)
            await prep(event, appState: appState)
            inFlightEventIds.remove(event.googleEventId)
        }
    }

    // MARK: - Prep a single event

    private func prep(_ event: CalendarEvent, appState: AppState) async {
        let context = gatherContext(for: event, appState: appState)
        let prompt = buildPrompt(event: event, context: context)
        let systemPrompt = appState.claude.buildSystemPrompt(from: appState)
        // OttoToolExecutor is @MainActor-isolated — hop to construct it.
        let executor = await MainActor.run { OttoToolExecutor(appState: appState) }

        let briefText: String
        do {
            let userTurn = ChatTurn(role: "user", blocks: [.text(prompt)])
            let turns = try await claudeCLI.streamChatWithTools(
                turns: [userTurn],
                systemPrompt: systemPrompt,
                tools: OttoTools.all,
                executor: executor,
                onDelta: { _ in },
                onEvent: { _ in }
            )
            briefText = turns.last?.blocks.compactMap { block -> String? in
                if case .text(let s) = block { return s }
                return nil
            }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            NSLog("[MeetingPrep] Claude run failed for \(event.title): \(error.localizedDescription)")
            return
        }

        guard !briefText.isEmpty else {
            NSLog("[MeetingPrep] empty brief for \(event.title); skipping")
            return
        }

        let note = Note(
            title: "Prep: \(event.title)",
            content: briefText,
            primaryCategory: .work,
            domainTagIds: []
        )
        await appState.addNote(note)

        let fireAt = event.startTime.addingTimeInterval(-notifyLead)
        if fireAt > Date() {
            let bodyLine = firstSentence(briefText)
            do {
                _ = try await notifications.scheduleNote(
                    noteId: note.id,
                    title: "Meeting in 10 min: \(event.title)",
                    body: bodyLine,
                    fireAt: fireAt
                )
            } catch {
                NSLog("[MeetingPrep] failed to schedule notification for \(event.title): \(error.localizedDescription)")
            }
        }

        var set = preppedEventIds
        set.insert(event.googleEventId)
        preppedEventIds = set

        NSLog("[MeetingPrep] prepped \(event.title) (attendees: \(event.attendees.count))")
    }

    // MARK: - Context gathering

    private struct AttendeeContext {
        let email: String
        let connection: Connection?
        let recentEmails: [Email]
        let recentTranscripts: [FirefliesTranscript]
    }

    private func gatherContext(for event: CalendarEvent, appState: AppState) -> [AttendeeContext] {
        return event.attendees.compactMap { email in
            let lowercasedEmail = email.lowercased()
            let connection = appState.connections.first(where: { $0.email?.lowercased() == lowercasedEmail })

            let emails = appState.emails
                .filter { $0.sender.lowercased().contains(lowercasedEmail) }
                .sorted(by: { $0.receivedDate > $1.receivedDate })
                .prefix(maxItemsPerSource)

            let transcripts = appState.firefliesTranscripts
                .filter { transcript in
                    guard let participants = transcript.participants else { return false }
                    return participants.contains(where: { $0.lowercased().contains(lowercasedEmail) })
                }
                .sorted(by: { ($0.date ?? 0) > ($1.date ?? 0) })
                .prefix(maxItemsPerSource)

            return AttendeeContext(
                email: email,
                connection: connection,
                recentEmails: Array(emails),
                recentTranscripts: Array(transcripts)
            )
        }
    }

    // MARK: - Prompt

    private func buildPrompt(event: CalendarEvent, context: [AttendeeContext]) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var lines: [String] = []
        lines.append("You're prepping me for a meeting. Compose a 3-sentence brief — voice-friendly, no bullets, no headers. Cover: who the attendees are, the most recent signal from Gmail or Fireflies, and one thing worth doing or asking in the meeting.")
        lines.append("")
        lines.append("Meeting: \"\(event.title)\" on \(df.string(from: event.startTime))")
        if let location = event.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }
        if let desc = event.description, !desc.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Description: \(desc.prefix(400))")
        }
        lines.append("")

        if context.isEmpty {
            lines.append("No attendee list attached to the event.")
        } else {
            lines.append("Attendees and what we know about each:")
            for ctx in context {
                lines.append("")
                lines.append("- \(ctx.email)")
                if let c = ctx.connection {
                    let name = [c.firstName, c.lastName].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    var line = "    Connection: \(name.isEmpty ? ctx.email : name)"
                    if !c.headline.isEmpty { line += " — \(c.headline)" }
                    if !c.company.isEmpty { line += " at \(c.company)" }
                    lines.append(line)
                    if !c.notes.isEmpty {
                        lines.append("    Notes: \(c.notes.prefix(200))")
                    }
                }
                if !ctx.recentEmails.isEmpty {
                    lines.append("    Recent Gmail:")
                    for e in ctx.recentEmails {
                        lines.append("      · [\(df.string(from: e.receivedDate))] \(e.subject) — \(e.snippet.prefix(150))")
                    }
                }
                if !ctx.recentTranscripts.isEmpty {
                    lines.append("    Recent Fireflies meetings:")
                    for t in ctx.recentTranscripts {
                        let when = t.date.map { df.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? "(unknown date)"
                        let title = t.title ?? "(untitled)"
                        lines.append("      · [\(when)] \(title)")
                        if let overview = t.summary?.overview, !overview.isEmpty {
                            lines.append("        \(overview.prefix(200))")
                        }
                    }
                }
            }
        }

        lines.append("")
        lines.append("CRITICAL: Use ONLY the context above. Do not call any tools — no search_items, no WebSearch, nothing. Just synthesize. Keep it to 3 short sentences. Output only the brief text, no preamble like \"here's your brief\".")
        return lines.joined(separator: "\n")
    }

    private func firstSentence(_ text: String) -> String {
        guard let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) else {
            return String(text.prefix(140))
        }
        return String(text[..<range.upperBound])
    }
}
