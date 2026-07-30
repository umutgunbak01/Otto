import SwiftUI

struct HabitListView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: HabitFilter = .today
    @State private var selectedHabitId: UUID?
    @State private var showCreator = false

    enum HabitFilter: String, CaseIterable, Identifiable {
        case today = "Today"
        case all = "All"
        case archived = "Archived"
        var id: String { rawValue }
    }

    // MARK: - Source data

    private var activeHabits: [Habit] {
        appState.habits.filter { !$0.isArchived }
    }

    private var visibleHabits: [Habit] {
        switch filter {
        case .today:
            return activeHabits.filter { $0.isRequired(on: Date()) }
        case .all:
            return activeHabits
        case .archived:
            return appState.habits.filter { $0.isArchived }
        }
    }

    // Required-today subset, used for the score cards.
    private var requiredToday: [Habit] {
        activeHabits.filter { $0.isRequired(on: Date()) }
    }

    private var metToday: Int {
        requiredToday.filter { $0.isMet(on: Date()) }.count
    }

    private var todayScore: Double {
        guard !requiredToday.isEmpty else { return 0 }
        return Double(metToday) / Double(requiredToday.count)
    }

    private var avgStreak: Int {
        guard !activeHabits.isEmpty else { return 0 }
        let sum = activeHabits.reduce(0) { $0 + $1.currentStreak() }
        return sum / activeHabits.count
    }

    /// Longest current streak among active habits + the habit holding it.
    private var bestStreak: (days: Int, holder: String?) {
        var best: (days: Int, title: String)?
        for habit in activeHabits {
            let s = habit.currentStreak()
            if best == nil || s > best!.days {
                best = (s, habit.title)
            }
        }
        guard let top = best, top.days > 0 else { return (best?.days ?? 0, nil) }
        return (top.days, shortTitle(top.title))
    }

    /// Met-required-days / required-days this calendar month, across active
    /// habits (same isRequired/isMet math the streaks use — display only).
    private var monthRate: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let monthStart = cal.dateInterval(of: .month, for: today)?.start else { return 0 }
        var met = 0
        var required = 0
        for habit in activeHabits {
            let created = cal.startOfDay(for: habit.createdAt)
            var day = monthStart
            while day <= today {
                if day >= created, habit.isRequired(on: day) {
                    required += 1
                    if habit.isMet(on: day) { met += 1 }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        guard required > 0 else { return 0 }
        return Int((Double(met) / Double(required) * 100).rounded())
    }

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: Date())
    }

    private func shortTitle(_ title: String) -> String {
        let first = title.split(separator: " ").first.map(String.init) ?? title
        return first.count > 12 ? String(first.prefix(12)) + "…" : first
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                viewbar
                if visibleHabits.isEmpty {
                    emptyState
                } else {
                    habitList
                }
            }

            if let id = selectedHabitId,
               let habit = appState.habits.first(where: { $0.id == id }) {
                Theme.Colors.bg1.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedHabitId = nil }
                    }
                HabitDetailView(habit: habit) {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedHabitId = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedHabitId)
        .sheet(isPresented: $showCreator) {
            HabitCreatorSheet()
        }
    }

    // MARK: - Viewbar

    private var viewbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Habits")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(activeHabits.count) active")

            OttoPillRail(
                options: [
                    (HabitFilter.today, "Today"),
                    (HabitFilter.all, "All"),
                    (HabitFilter.archived, "Archived"),
                ],
                selection: $filter
            )
            .padding(.leading, 4)

            Spacer(minLength: 8)

            OttoNewButton(label: "New habit") {
                showCreator = true
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Score cards

    private var scoreCards: some View {
        HStack(spacing: 12) {
            scoreCard(label: "Today", value: "\(metToday) / \(requiredToday.count)", unit: "due") {
                ProgressBar(progress: todayScore, color: Theme.Colors.accent)
                    .frame(height: 3)
                    .padding(.top, 3)
            }
            scoreCard(label: "Avg streak", value: "\(avgStreak)", unit: "days")
            scoreCard(
                label: "Best streak",
                value: "\(bestStreak.days)",
                unit: bestStreak.holder.map { "days · \($0)" } ?? "days"
            )
            scoreCard(label: monthName, value: "\(monthRate)", unit: "%")
        }
    }

    private func scoreCard(label: String, value: String, unit: String?) -> some View {
        scoreCard(label: label, value: value, unit: unit) { EmptyView() }
    }

    private func scoreCard<Footer: View>(
        label: String,
        value: String,
        unit: String?,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(Theme.Tracking.xxwide)
                .foregroundStyle(Theme.Colors.tertiaryText)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 21, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.text)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Week header

    /// Right-aligned M–S letters sitting above the rows' week-dot columns
    /// (shares layout constants with HabitRowView so they line up).
    private var weekHeader: some View {
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        let todayIndex = (Calendar.current.component(.weekday, from: Date()) + 5) % 7
        return HStack(spacing: HabitRowView.dotSpacing) {
            ForEach(0..<7, id: \.self) { i in
                Text(letters[i])
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(i == todayIndex ? Theme.Colors.text : Theme.Colors.tertiaryText)
                    .frame(width: HabitRowView.dotSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, HabitRowView.weekTrailingInset)
    }

    // MARK: - List

    private var habitList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                scoreCards
                    .padding(.bottom, 18)

                weekHeader
                    .padding(.bottom, 6)

                LazyVStack(spacing: 2) {
                    ForEach(visibleHabits) { habit in
                        HabitRowView(habit: habit, isSelected: selectedHabitId == habit.id) {
                            selectedHabitId = habit.id
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "repeat",
            title: emptyTitle,
            message: emptyMessage,
            tip: "Habits can auto-log from meetings and chat"
        ) {
            if filter != .archived {
                OttoNewButton(label: "Create your first habit") {
                    showCreator = true
                }
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .today: return activeHabits.isEmpty ? "No habits yet" : "Nothing due today"
        case .all: return "No habits yet"
        case .archived: return "No archived habits"
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .today where !activeHabits.isEmpty:
            return "None of your habits are scheduled for today."
        case .archived:
            return "Habits you archive will show up here."
        default:
            return "Create a habit to start tracking streaks and daily progress."
        }
    }
}

// MARK: - Progress bar

struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.Colors.hoverTint)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
    }
}
