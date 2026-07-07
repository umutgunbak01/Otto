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

    // Required-today subset, used for the score header.
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

    var body: some View {
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                OttoDivider()
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

    // MARK: - Header (today score + filters)

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Habits")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                Button {
                    showCreator = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("New Habit")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(AccentButtonStyle())
            }

            scoreCard

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(HabitFilter.allCases) { f in
                    filterPill(f)
                }
                Spacer()
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                scoreCell(label: "Today", value: "\(metToday)/\(requiredToday.count)", color: Theme.Colors.text)
                scoreCell(label: "Avg streak", value: "\(avgStreak)", color: Theme.Colors.amber)
                scoreCell(label: "Active", value: "\(activeHabits.count)", color: Theme.Colors.text)
            }

            ProgressBar(progress: todayScore, color: Theme.Colors.accent)
                .frame(height: 3)
        }
    }

    private func scoreCell(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(Theme.Tracking.xwide)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.tertiaryText)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func filterPill(_ f: HabitFilter) -> some View {
        let isActive = filter == f
        return Button {
            filter = f
        } label: {
            Text(f.rawValue)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 5)
                .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.textDim)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Theme.Colors.selectTint : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var habitList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(visibleHabits) { habit in
                    HabitRowView(habit: habit) {
                        selectedHabitId = habit.id
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "flame")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Colors.textDim)
            Text(filter == .archived ? "No archived habits." : "No habits yet.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textDim)
            if filter != .archived {
                Button {
                    showCreator = true
                } label: {
                    Text("Create your first habit")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AccentButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
