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
                Divider().background(Theme.Colors.border)
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
                Text("HABITS")
                    .hudLabel(tracking: Theme.Tracking.xxwide, color: Theme.Colors.cyan)
                Spacer()
                Button {
                    showCreator = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("NEW HABIT")
                            .font(Theme.Typography.label)
                            .tracking(Theme.Tracking.wide)
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
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .hudLabel(tracking: Theme.Tracking.wide)
                    Text("\(metToday) / \(requiredToday.count)")
                        .font(Theme.Typography.largeTitle)
                        .foregroundStyle(Theme.Colors.cyan)
                        .neonGlow(intensity: 0.6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("AVG STREAK")
                        .hudLabel(tracking: Theme.Tracking.wide)
                    Text("\(avgStreak)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE")
                        .hudLabel(tracking: Theme.Tracking.wide)
                    Text("\(activeHabits.count)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.text)
                }
                Spacer()
            }

            ProgressBar(progress: todayScore, color: Theme.Colors.cyan)
                .frame(height: 4)
        }
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    private func filterPill(_ f: HabitFilter) -> some View {
        let isActive = filter == f
        return Button {
            filter = f
        } label: {
            Text(f.rawValue.uppercased())
                .font(Theme.Typography.label)
                .tracking(Theme.Tracking.wide)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .foregroundStyle(isActive ? Theme.Colors.cyan : Theme.Colors.textDim)
                .overlay(
                    Rectangle()
                        .stroke(isActive ? Theme.Colors.cyan : Theme.Colors.borderSubtle, lineWidth: 1)
                )
                .background(isActive ? Theme.Colors.cyan.opacity(0.08) : Color.clear)
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
                    Text("CREATE YOUR FIRST HABIT")
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.wide)
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
                Rectangle()
                    .fill(color.opacity(0.12))
                Rectangle()
                    .fill(LinearGradient(
                        colors: [color.opacity(0.6), color],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
                    .shadow(color: color.opacity(0.5), radius: 4)
            }
        }
    }
}
