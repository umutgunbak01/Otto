import SwiftUI

struct HabitDetailView: View {
    @Environment(AppState.self) private var appState
    let habit: Habit
    let onClose: () -> Void

    private var current: Habit {
        appState.habits.first(where: { $0.id == habit.id }) ?? habit
    }

    private var color: Color { current.colorTag.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    statsBlock
                    heatmap
                    historyList
                    actions
                }
                .padding(Theme.Spacing.lg)
            }
        }
        .frame(maxWidth: 720, maxHeight: 640)
        .background(Theme.Colors.bg1)
        .overlay(Rectangle().stroke(Theme.Colors.cyan.opacity(0.4), lineWidth: 1))
        .neonGlow(color: Theme.Colors.cyan, intensity: 0.5)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: current.iconName)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: 1))
                .background(color.opacity(0.08))

            VStack(alignment: .leading, spacing: 2) {
                Text(current.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)
                Text("\(current.kind.displayName.uppercased()) · \(current.frequency.displayName.uppercased()) · \(current.category.displayName.uppercased())")
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.Colors.textDim)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Stats

    private var statsBlock: some View {
        HStack(spacing: Theme.Spacing.lg) {
            statCell(label: "TODAY", value: todayLabel, color: current.isMet(on: Date()) ? color : Theme.Colors.text)
            statCell(label: "STREAK", value: "\(current.currentStreak())", color: Theme.Colors.amber)
            statCell(label: "BEST", value: "\(current.longestStreak())", color: Theme.Colors.green)
            statCell(label: "7-DAY", value: "\(Int(current.completionRate(lastDays: 7) * 100))%", color: Theme.Colors.cyan)
            statCell(label: "30-DAY", value: "\(Int(current.completionRate(lastDays: 30) * 100))%", color: Theme.Colors.cyanDim)
        }
    }

    private var todayLabel: String {
        let p = current.progress(on: Date())
        let t = current.dailyTarget
        let unit = current.unit.map { " \($0)" } ?? ""
        if current.kind == .binary {
            return current.isMet(on: Date()) ? "✓" : "—"
        }
        return "\(format(p))/\(format(t))\(unit)"
    }

    private func statCell(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).hudLabel(tracking: Theme.Tracking.wide)
            Text(value)
                .font(Theme.Typography.title)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    // MARK: - Heatmap

    private var heatmap: some View {
        let weeks = 12
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Find the start of the week containing today, then go back (weeks-1) weeks.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstDay = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: weekStart) ?? weekStart

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("LAST \(weeks) WEEKS")
                .hudLabel(tracking: Theme.Tracking.wide)

            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = calendar.date(byAdding: .day, value: w * 7 + d, to: firstDay) ?? firstDay
                            cell(for: day, today: today)
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    private func cell(for day: Date, today: Date) -> some View {
        let inFuture = day > today
        let beforeStart = day < Calendar.current.startOfDay(for: current.createdAt)
        let progress = current.progress(on: day)
        let target = max(1, current.dailyTarget)
        let intensity: Double = {
            if inFuture || beforeStart { return 0 }
            return min(1, progress / target)
        }()
        return Rectangle()
            .fill(color.opacity(intensity > 0 ? 0.25 + intensity * 0.6 : 0.06))
            .frame(width: 12, height: 12)
            .overlay(Rectangle().stroke(color.opacity(intensity > 0 ? 0.7 : 0.15), lineWidth: 0.5))
            .help(dateLabel(day) + " · " + cellLabel(progress: progress, target: target))
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private func cellLabel(progress: Double, target: Double) -> String {
        if current.kind == .binary {
            return progress >= 1 ? "done" : "—"
        }
        let unit = current.unit ?? ""
        return "\(format(progress))/\(format(target))\(unit.isEmpty ? "" : " \(unit)")"
    }

    // MARK: - History

    private var historyList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("RECENT ENTRIES")
                .hudLabel(tracking: Theme.Tracking.wide)
            let recent = current.entries.sorted { $0.date > $1.date }.prefix(20)
            if recent.isEmpty {
                Text("No entries yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(recent), id: \.id) { entry in
                        entryRow(entry)
                    }
                }
                .background(Theme.Colors.panel)
                .overlay(Rectangle().strokeBorder(Theme.Colors.panelEdge, lineWidth: 1))
            }
        }
    }

    private func entryRow(_ entry: HabitEntry) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(formatDateTime(entry.date))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textDim)
                .frame(width: 130, alignment: .leading)
            let unit = current.unit ?? ""
            Text("\(format(entry.value))\(unit.isEmpty ? "" : " \(unit)")")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .frame(width: 90, alignment: .leading)
            if let n = entry.note, !n.isEmpty {
                Text(n)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await appState.deleteHabitEntry(habitId: current.id, entryId: entry.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            if current.isArchived {
                Button("UNARCHIVE") {
                    Task {
                        var u = current; u.isArchived = false
                        await appState.updateHabit(u)
                    }
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Button("ARCHIVE") {
                    Task {
                        var u = current; u.isArchived = true
                        await appState.updateHabit(u)
                        onClose()
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }

            Spacer()

            Button("DELETE") {
                Task {
                    await appState.deleteHabit(current)
                    onClose()
                }
            }
            .foregroundStyle(Theme.Colors.red)
            .buttonStyle(GhostButtonStyle())
        }
    }

    private func format(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.1f", n)
    }

    private func formatDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }
}
