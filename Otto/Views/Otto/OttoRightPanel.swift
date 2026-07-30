import SwiftUI

/// Right rail of Home — the agent-written daily briefing (mockup .brief).
///
/// Top to bottom: "Daily Briefing" overline + refresh, a next-meeting card
/// with a live countdown chip, the serif briefing headline + summary, then
/// the to-dos / schedule / heads-up sections, closed by a quiet mono footer.
/// Content comes from `DailyBriefingService`; the panel only renders states.
struct OttoRightPanel: View {
    @Environment(AppState.self) private var appState

    private var service: DailyBriefingService { .shared }

    /// Briefing to-dos the user ticked in this session that had no matching
    /// real todo — kept locally so the checkmark still responds.
    @State private var locallyDone: Set<String> = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header

                if let next = nextEvent(now: .now) {
                    meetingCard(next)
                        .padding(.bottom, 4)
                }

                if let briefing = service.briefing {
                    briefingBody(briefing)
                } else if service.isGenerating {
                    loadingState
                } else {
                    emptyState
                }

                if hasAnyCadence {
                    keepInTouchSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.panelWash)
        .task {
            service.ensureFresh(appState: appState)
        }
    }

    // MARK: - Header

    // MARK: - Keep in touch

    private var hasAnyCadence: Bool {
        appState.networkEntries.contains { $0.followUpCadence != nil }
    }

    /// Network Hub people whose follow-up cadence has lapsed, most overdue
    /// first. The section only renders once at least one person has a cadence.
    private var dueFollowUps: [(entry: NetworkEntry, overdueDays: Int)] {
        appState.networkEntries
            .compactMap { entry in entry.followUpOverdueDays().map { (entry, $0) } }
            .sorted { $0.1 > $1.1 }
    }

    @ViewBuilder
    private var keepInTouchSection: some View {
        let due = dueFollowUps
        sectionRule
        HStack(spacing: 8) {
            OttoOverline(text: "Keep in touch")
            if !due.isEmpty {
                Text("\(due.count)")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Colors.panel2))
                    .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
            }
        }
        .padding(.bottom, 6)

        if due.isEmpty {
            Text("All caught up.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.tertiaryText)
        } else {
            ForEach(Array(due.prefix(5).enumerated()), id: \.element.entry.id) { index, item in
                followUpRow(item.entry, overdueDays: item.overdueDays, isFirst: index == 0)
            }
            if due.count > 5 {
                Text("+ \(due.count - 5) more in Network hub")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func followUpRow(_ entry: NetworkEntry, overdueDays: Int, isFirst: Bool) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(overdueDays >= 7 ? Theme.Colors.red : Theme.Colors.amber)
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.isEmpty ? entry.company : entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text(followUpSubtitle(entry, overdueDays: overdueDays))
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button("Draft outreach") { draftOutreach(entry) }
                Button("Mark contacted") { markContacted(entry) }
                Button("Snooze 1 week") { snooze(entry) }
                Divider()
                Button("Open person") { appState.locate(type: .networkHub, id: entry.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
        }
        .padding(.top, isFirst ? 0 : 9)
        .contentShape(Rectangle())
        .onTapGesture { appState.locate(type: .networkHub, id: entry.id) }
    }

    private func followUpSubtitle(_ entry: NetworkEntry, overdueDays: Int) -> String {
        let overdue = overdueDays == 0 ? "due today" : "\(overdueDays)d overdue"
        if let cadence = entry.followUpCadence {
            return "\(overdue) · every \(cadence.shortLabel)"
        }
        return overdue
    }

    private func draftOutreach(_ entry: NetworkEntry) {
        let who = [entry.name, entry.displayInfo].filter { !$0.isEmpty }.joined(separator: " — ")
        appState.pendingChatPrompt = """
        Draft a short, warm re-engagement message to \(who). Use semantic_search \
        (and get_item on the best hits) to ground it in our most recent interactions — \
        reference something concrete from the last touchpoint, match my usual tone, keep it \
        under 120 words, and if email is the natural channel include a subject line. \
        Show me the draft only — don't send anything.
        """
    }

    private func markContacted(_ entry: NetworkEntry) {
        var updated = entry
        updated.lastContactedAt = Date()
        updated.followUpSnoozedUntil = nil
        Task { await appState.updateNetworkEntry(updated) }
    }

    private func snooze(_ entry: NetworkEntry) {
        var updated = entry
        updated.followUpSnoozedUntil = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        Task { await appState.updateNetworkEntry(updated) }
    }

    private var header: some View {
        HStack {
            OttoOverline(text: "Daily Briefing")
            Spacer()
            if service.isGenerating {
                ProgressView()
                    .controlSize(.small)
            } else {
                OttoGlyphButton(systemImage: "arrow.clockwise", help: "Regenerate briefing") {
                    service.refresh(appState: appState)
                }
            }
        }
        .frame(height: 28)
        .padding(.bottom, 12)
    }

    // MARK: - States

    @ViewBuilder
    private func briefingBody(_ briefing: DailyBriefing) -> some View {
        if !briefing.headline.isEmpty {
            Text(briefing.headline)
                .font(Theme.Typography.displayMd)
                .foregroundStyle(Theme.Colors.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
        if !briefing.summary.isEmpty {
            Text(briefing.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.textDim)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)
        }

        if !briefing.todos.isEmpty {
            sectionRule
            HStack(spacing: 8) {
                OttoOverline(text: "To-dos")
                Text("\(briefing.todos.count)")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Colors.panel2))
                    .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
            }
            .padding(.bottom, 6)

            ForEach(Array(briefing.todos.enumerated()), id: \.offset) { _, todo in
                BriefingTodoRow(
                    todo: todo,
                    isDone: isDone(todo),
                    onToggle: { toggle(todo) }
                )
            }
        }

        if !briefing.events.isEmpty {
            sectionRule
            OttoOverline(text: "Schedule")
                .padding(.bottom, 6)
            ForEach(Array(briefing.events.enumerated()), id: \.offset) { index, event in
                BriefingEventRow(event: event, isFirst: index == 0)
            }
        }

        if !briefing.headsUp.isEmpty {
            sectionRule
            OttoOverline(text: "Heads-up")
                .padding(.bottom, 6)
            ForEach(Array(briefing.headsUp.enumerated()), id: \.offset) { index, item in
                BriefingHeadsUpRow(text: item, isFirst: index == 0)
            }
        }

        footer(briefing)
    }

    /// Soft gradient rule between sections (mockup .hr).
    private var sectionRule: some View {
        LinearGradient(
            colors: [.clear, Color.white.opacity(0.09), Color.white.opacity(0.09), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.vertical, 20)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reading your day…")
                .font(Theme.Typography.displaySm.italic())
                .foregroundStyle(Theme.Colors.textDim)
            Text("Checking your calendar, to-dos, and recent history.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = service.lastError {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your agent writes a morning summary here — schedule with prep notes, the to-dos that matter, and anything to watch.")
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if service.canGenerate {
                OttoChip(text: service.lastError == nil ? "Generate briefing" : "Try again") {
                    service.refresh(appState: appState)
                }
            }
        }
        .padding(.top, 16)
    }

    private func footer(_ briefing: DailyBriefing) -> some View {
        VStack(spacing: 14) {
            sectionRule
                .padding(.vertical, 0)
            HStack(spacing: 6) {
                Spacer()
                Text("Updated \(Self.timeFormatter.string(from: briefing.generatedAt)) · by \(AgentBackend.current.rawValue)".uppercased())
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .tracking(Theme.Tracking.xxwide)
                    .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.8))
                if let error = service.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.amber)
                        .help("Last refresh failed: \(error)")
                }
                Spacer()
            }
        }
        .padding(.top, 22)
    }

    // MARK: - Briefing to-do interactivity

    /// A briefing to-do is "done" when a real todo with the same title is
    /// completed, or when the user ticked it locally (no match found).
    private func isDone(_ todo: DailyBriefing.TodoItem) -> Bool {
        if let match = matchingTodo(todo) { return match.isCompleted }
        return locallyDone.contains(todo.title)
    }

    private func matchingTodo(_ todo: DailyBriefing.TodoItem) -> Todo? {
        let target = todo.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return appState.todos.first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }

    private func toggle(_ todo: DailyBriefing.TodoItem) {
        if let match = matchingTodo(todo) {
            Task { await appState.toggleTodo(match) }
        } else if locallyDone.contains(todo.title) {
            locallyDone.remove(todo.title)
        } else {
            locallyDone.insert(todo.title)
        }
    }

    // MARK: - Next meeting card (live countdown, independent of the agent)

    private func meetingCard(_ next: CalendarEvent) -> some View {
        HStack(spacing: 13) {
            VStack(spacing: 3) {
                Text(Self.weekdayFormatter.string(from: next.startTime).uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(Self.dayFormatter.string(from: next.startTime))
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.text)
                Text(Self.monthFormatter.string(from: next.startTime).uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(minWidth: 28)

            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(next.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(2)
                Text(Self.eventTimeLabel(for: next.startTime).uppercased())
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // Amber meeting spine (mockup .meet::before).
            LinearGradient(
                colors: [Theme.Colors.amber.opacity(0.75), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 2)
            .padding(.vertical, 11)
        }
        .overlay(alignment: .bottomTrailing) {
            NextEventCountdown(target: next.startTime)
                .padding(10)
        }
    }

    private func nextEvent(now: Date) -> CalendarEvent? {
        appState.calendarEvents
            .filter { $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    private static func eventTimeLabel(for date: Date) -> String {
        let cal = Calendar.current
        let time = timeFormatter.string(from: date)
        if cal.isDateInToday(date) { return "Today · \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow · \(time)" }
        return "\(weekdayFormatter.string(from: date)) · \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()
}

// MARK: - Countdown — its own subview so the timer doesn't ripple the panel

private struct NextEventCountdown: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(format(now: ctx.date))
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Colors.amber)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Colors.tintAmber)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.Colors.amber.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private func format(now: Date) -> String {
        let delta = max(0, target.timeIntervalSince(now))
        let totalMinutes = Int(delta) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h >= 48 {
            let d = h / 24
            return "in \(d) days"
        }
        if h > 0 {
            return String(format: "in %dh %02dm", h, m)
        }
        return "in \(m)m"
    }
}

// MARK: - Briefing rows

/// Checkbox to-do row (mockup .todo) — rounded-square check, title, note.
private struct BriefingTodoRow: View {
    let todo: DailyBriefing.TodoItem
    let isDone: Bool
    let onToggle: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5)
                        .strokeBorder(
                            isDone ? Theme.Colors.cyan.opacity(0.45) : Color.white.opacity(0.22),
                            lineWidth: 1.5
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 5.5)
                                .fill(isDone ? Theme.Colors.tintTeal : Color.clear)
                        )
                        .frame(width: 16, height: 16)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Colors.cyan)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(todo.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isDone ? Theme.Colors.tertiaryText : Theme.Colors.text)
                    .strikethrough(isDone, color: Color.white.opacity(0.22))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = todo.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if todo.isHighUrgency && !isDone {
                Circle()
                    .fill(Theme.Colors.amber)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(hover ? Theme.Colors.panel : Color.clear)
        )
        .padding(.horizontal, -10)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: hover)
    }
}

private struct BriefingEventRow: View {
    let event: DailyBriefing.EventItem
    var isFirst: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(event.time.isEmpty ? "—" : event.time)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.accentText)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let loc = event.location, !loc.isEmpty {
                    Text(loc)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
                if !event.note.isEmpty {
                    Text(event.note)
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if !isFirst { OttoDivider(color: Theme.Colors.borderSubtle) }
        }
    }
}

private struct BriefingHeadsUpRow: View {
    let text: String
    var isFirst: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(Theme.Colors.amber)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Theme.Colors.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if !isFirst { OttoDivider(color: Theme.Colors.borderSubtle) }
        }
    }
}
