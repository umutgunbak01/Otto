import SwiftUI

/// Right rail of the Otto HUD — three stacked panels:
///   1. NEXT EVENT — countdown to the next calendar event
///   2. INTEL FEED — live signal feed pulled from real app state
///   3. VITALS — quick four-tile dashboard
struct OttoRightPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 14) {
            nextEventPanel
            intelFeedPanel
                .frame(maxHeight: .infinity)
            vitalsPanel
        }
    }

    // MARK: - Panel chrome

    private struct PanelChrome<Content: View>: View {
        let title: String
        let id: String
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Theme.Colors.cyan)
                        .shadow(color: Theme.Colors.cyanGlow, radius: 4)
                    Spacer()
                    Text(id)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    DashedLine()
                        .stroke(
                            Theme.Colors.cyan.opacity(0.22),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                        .frame(height: 1)
                }

                content
                    .padding(.top, 10)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .angledPanel(.topRightBottomLeft(14))
        }
    }

    // MARK: - Next event
    //
    // Only the countdown text needs second-by-second updates. Pulling the
    // timeline up to wrap PanelChrome rebuilt the entire panel every second;
    // we now scope the timeline to the countdown itself and let everything
    // else render once per data change.

    private var nextEventPanel: some View {
        let next = nextEvent(now: .now)
        return PanelChrome(title: "⌬ NEXT EVENT", id: nextEventId(event: next)) {
            if let next = next {
                VStack(alignment: .leading, spacing: 6) {
                    NextEventCountdown(target: next.startTime)
                    Text(next.title.uppercased())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    Text(OttoFormatters.eventDate.string(from: next.startTime).uppercased())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                    if let loc = next.location, !loc.isEmpty {
                        Text(loc.uppercased())
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("--:--")
                        .font(Theme.Typography.timer)
                        .foregroundStyle(Theme.Colors.cyan.opacity(0.4))
                    Text("NO UPCOMING EVENTS")
                        .font(Theme.Typography.caption)
                        .tracking(2)
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
        }
    }

    // MARK: - Intel feed

    private var intelFeedPanel: some View {
        PanelChrome(title: "⌬ INTEL FEED", id: "LIVE") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(intelItems) { item in
                        FeedRow(item: item)
                    }
                    if intelItems.isEmpty {
                        Text("ALL QUIET. NEURAL CHANNEL OPEN.")
                            .font(Theme.Typography.caption)
                            .tracking(2)
                            .foregroundStyle(Theme.Colors.textDim)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var intelItems: [IntelItem] {
        var items: [IntelItem] = []

        // Critical: most recent unread email from a known sender.
        if let email = appState.emails.filter({ !$0.isRead }).sorted(by: { $0.receivedDate > $1.receivedDate }).first {
            let from = email.sender.split(separator: "<").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? email.sender
            items.append(IntelItem(
                id: "email-\(email.id)",
                tag: .red,
                title: "\(from) → \(email.subject)",
                meta: "EMAIL · \(relative(email.receivedDate)) · CRITICAL"
            ))
        }

        // Amber: overdue todos.
        let overdue = appState.todos.filter {
            !$0.isCompleted && ($0.dueDate.map { $0 < .now } ?? false)
        }.count
        if overdue > 0 {
            items.append(IntelItem(
                id: "overdue-todos",
                tag: .amber,
                title: "\(overdue) todos shifted from yesterday",
                meta: "SYSTEM · NOW"
            ))
        }

        // Cyan: most recent meeting transcript.
        if let m = appState.meetings.sorted(by: { $0.meetingDate > $1.meetingDate }).first {
            items.append(IntelItem(
                id: "meeting-\(m.id)",
                tag: .cyan,
                title: "Transcript ready: \"\(m.title)\"",
                meta: "FIREFLIES · \(relative(m.meetingDate))"
            ))
        }

        // Cyan: latest connection.
        if let c = appState.connections.sorted(by: { ($0.connectionDate ?? $0.importedAt) > ($1.connectionDate ?? $1.importedAt) }).first {
            items.append(IntelItem(
                id: "conn-\(c.id)",
                tag: .cyan,
                title: "New connection: \(c.fullName)",
                meta: "LINKEDIN · \(relative(c.connectionDate ?? c.importedAt))"
            ))
        }

        // Cyan: bookmarks added today.
        let todayBookmarks = appState.bookmarks.filter { Calendar.current.isDateInToday($0.updatedAt) }.count
        if todayBookmarks > 0 {
            items.append(IntelItem(
                id: "bookmarks-today",
                tag: .cyan,
                title: "\(todayBookmarks) new bookmarks indexed",
                meta: "SYSTEM · TODAY"
            ))
        }

        return Array(items.prefix(6))
    }

    // MARK: - Vitals

    private var vitalsPanel: some View {
        PanelChrome(title: "⌬ VITALS", id: "SYS") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                VitalCell(label: "FOCUS",  value: focusLabel,        tone: focusTone)
                VitalCell(label: "INBOX",  value: "\(unreadEmails)", tone: unreadEmails > 50 ? .warn : .normal)
                VitalCell(label: "TODAY",  value: todoProgressLabel, tone: .normal)
                VitalCell(label: "OVERDUE", value: "\(overdueCount)", tone: overdueCount > 0 ? .alert : .ok)
            }
        }
    }

    private var unreadEmails: Int { appState.emails.filter { !$0.isRead }.count }

    private var overdueCount: Int {
        appState.todos.filter { !$0.isCompleted && ($0.dueDate.map { $0 < .now } ?? false) }.count
    }

    private var todoProgressLabel: String {
        let today = appState.todos.filter {
            Calendar.current.isDateInToday($0.dueDate ?? .distantPast) || Calendar.current.isDateInToday($0.updatedAt)
        }
        let done = today.filter { $0.isCompleted }.count
        return "\(done)/\(today.count)"
    }

    private var focusLabel: String {
        if let until = appState.quietUntil, until > .now { return "QUIET" }
        switch appState.voice.phase {
        case .listening, .transcribing: return "LIVE"
        case .speaking, .thinking: return "ACTIVE"
        case .error: return "ERR"
        case .idle: return "DEEP"
        }
    }

    private var focusTone: VitalTone {
        if case .error = appState.voice.phase { return .alert }
        if appState.quietUntil.map({ $0 > .now }) == true { return .normal }
        return .normal
    }

    // MARK: - Helpers

    private func nextEvent(now: Date) -> CalendarEvent? {
        appState.calendarEvents
            .filter { $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    private func nextEventId(event: CalendarEvent?) -> String {
        guard let next = event else { return "—" }
        let raw = next.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(4)
        return "EV-\(raw.uppercased())"
    }

    private func relative(_ d: Date) -> String {
        let secs = Date().timeIntervalSince(d)
        if secs < 60 { return "JUST NOW" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m AGO" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h AGO" }
        let days = hours / 24
        return "\(days)d AGO"
    }
}

// MARK: - Countdown — its own subview so the timer doesn't ripple the panel

private struct NextEventCountdown: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (text, unit) = format(now: ctx.date)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .font(Theme.Typography.timer)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 14)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.textDim)
            }
        }
    }

    private func format(now: Date) -> (String, String) {
        let delta = max(0, target.timeIntervalSince(now))
        let totalMinutes = Int(delta) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h >= 100 {
            let d = h / 24
            let rh = h % 24
            return (String(format: "%dd:%02d", d, rh), "DAY · HRS")
        }
        return (String(format: "%02d:%02d", h, m), "HRS · MIN")
    }
}

// MARK: - Feed row

private enum FeedTag { case cyan, amber, red }

private struct IntelItem: Identifiable {
    let id: String
    let tag: FeedTag
    let title: String
    let meta: String
}

private struct FeedRow: View {
    let item: IntelItem

    private var color: Color {
        switch item.tag {
        case .cyan:  return Theme.Colors.cyan
        case .amber: return Theme.Colors.amber
        case .red:   return Theme.Colors.red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
                .shadow(color: color.opacity(0.6), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(2)
                Text(item.meta)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.Colors.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            DashedLine()
                .stroke(
                    Theme.Colors.cyan.opacity(0.10),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                )
                .frame(height: 1)
        }
    }
}

// MARK: - Vital cell

enum VitalTone { case normal, warn, alert, ok }

private struct VitalCell: View {
    let label: String
    let value: String
    let tone: VitalTone

    var color: Color {
        switch tone {
        case .normal: return Theme.Colors.cyan
        case .warn:   return Theme.Colors.amber
        case .alert:  return Theme.Colors.red
        case .ok:     return Theme.Colors.green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.Colors.textDim)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.6), radius: 4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle().stroke(Theme.Colors.cyan.opacity(0.18), lineWidth: 1)
        )
    }
}
