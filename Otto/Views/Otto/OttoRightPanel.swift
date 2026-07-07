import SwiftUI

/// Right rail of Home — the agent-written daily briefing.
///
/// One card: a live next-event countdown strip (deterministic, ticks every
/// minute), then the generated sections — headline + summary, today's
/// schedule with prep notes the agent researched from past meetings / notes /
/// emails, the to-dos that matter today, and heads-up items. Content comes
/// from `DailyBriefingService`; the panel only renders states.
struct OttoRightPanel: View {
    @Environment(AppState.self) private var appState

    private var service: DailyBriefingService { .shared }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                briefingCard
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.bg1)
        .overlay(alignment: .leading) {
            OttoDivider()
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .task {
            service.ensureFresh(appState: appState)
        }
    }

    // MARK: - Briefing card

    private var briefingCard: some View {
        Card(title: "Daily briefing", accessory: { headerAccessory }) {
            VStack(alignment: .leading, spacing: 13) {
                if let next = nextEvent(now: .now) {
                    nextEventStrip(next)
                }

                if let briefing = service.briefing {
                    briefingBody(briefing)
                } else if service.isGenerating {
                    loadingState
                } else {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        if service.isGenerating {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                service.refresh(appState: appState)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Regenerate briefing")
        }
    }

    // MARK: - States

    @ViewBuilder
    private func briefingBody(_ briefing: DailyBriefing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !briefing.headline.isEmpty {
                Text(briefing.headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !briefing.summary.isEmpty {
                Text(briefing.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !briefing.events.isEmpty {
            section("Schedule") {
                ForEach(Array(briefing.events.enumerated()), id: \.offset) { index, event in
                    EventRow(event: event, isFirst: index == 0)
                }
            }
        }

        if !briefing.todos.isEmpty {
            section("To-dos") {
                ForEach(Array(briefing.todos.enumerated()), id: \.offset) { index, todo in
                    TodoRow(todo: todo, isFirst: index == 0)
                }
            }
        }

        if !briefing.headsUp.isEmpty {
            section("Heads-up") {
                ForEach(Array(briefing.headsUp.enumerated()), id: \.offset) { index, item in
                    HeadsUpRow(text: item, isFirst: index == 0)
                }
            }
        }

        footer(briefing)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reading your day…")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textDim)
            Text("Checking your calendar, to-dos, and recent history.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = service.lastError {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your agent writes a morning summary here — schedule with prep notes, the to-dos that matter, and anything to watch.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if service.canGenerate {
                OttoChip(text: service.lastError == nil ? "Generate briefing" : "Try again") {
                    service.refresh(appState: appState)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func footer(_ briefing: DailyBriefing) -> some View {
        HStack(spacing: 6) {
            Text("Updated \(Self.timeFormatter.string(from: briefing.generatedAt))")
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.tertiaryText)
            if let error = service.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.amber)
                    .help("Last refresh failed: \(error)")
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Section chrome

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.Typography.label)
                .tracking(Theme.Tracking.xwide)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.bottom, 4)
            content()
        }
    }

    // MARK: - Next event strip (live countdown, independent of the agent)

    private func nextEventStrip(_ next: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text(OttoFormatters.eventDate.string(from: next.startTime))
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.textDim)
            }
            Spacer(minLength: 8)
            NextEventCountdown(target: next.startTime)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.selectTint.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func nextEvent(now: Date) -> CalendarEvent? {
        appState.calendarEvents
            .filter { $0.startTime > now }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Card chrome

    private struct Card<Content: View, Accessory: View>: View {
        let title: String
        @ViewBuilder var accessory: Accessory
        @ViewBuilder var content: Content

        init(
            title: String,
            @ViewBuilder accessory: () -> Accessory,
            @ViewBuilder content: () -> Content
        ) {
            self.title = title
            self.accessory = accessory()
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title.uppercased())
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.xwide)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Spacer()
                    accessory
                }
                .padding(.bottom, 10)

                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
        }
    }
}

// MARK: - Countdown — its own subview so the timer doesn't ripple the panel

private struct NextEventCountdown: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(format(now: ctx.date))
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.Colors.selectTint)
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

private struct EventRow: View {
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
                    .font(.system(size: 12.5, weight: .semibold))
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
                        .foregroundStyle(Theme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            if !isFirst { OttoDivider() }
        }
    }
}

private struct TodoRow: View {
    let todo: DailyBriefing.TodoItem
    var isFirst: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(todo.isHighUrgency ? Theme.Colors.amber : Theme.Colors.accent)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = todo.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if !isFirst { OttoDivider() }
        }
    }
}

private struct HeadsUpRow: View {
    let text: String
    var isFirst: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(Theme.Colors.amber)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if !isFirst { OttoDivider() }
        }
    }
}
