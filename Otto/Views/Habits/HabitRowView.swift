import SwiftUI

struct HabitRowView: View {
    @Environment(AppState.self) private var appState
    let habit: Habit
    let onTap: () -> Void

    @State private var showQuickLog = false
    @State private var quickLogValue: String = ""

    private var progress: Double { habit.progress(on: Date()) }
    private var target: Double { max(1, habit.dailyTarget) }
    private var ratio: Double { min(1, progress / target) }
    private var isMet: Bool { habit.isMet(on: Date()) }
    private var streak: Int { habit.currentStreak() }
    private var color: Color { habit.colorTag.color }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            iconBlock

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(habit.title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.text)
                    targetBadge
                }
                progressLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            streakChip

            actionButton
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.md)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Open Details") { onTap() }
            if habit.isArchived {
                Button("Unarchive") { Task { await unarchive() } }
            } else {
                Button("Archive") { Task { await archive() } }
            }
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .popover(isPresented: $showQuickLog, arrowEdge: .top) {
            quickLogPopover
        }
    }

    // MARK: - Pieces

    private var iconBlock: some View {
        ZStack {
            Rectangle()
                .stroke(color.opacity(isMet ? 0.9 : 0.35), lineWidth: 1)
                .background(Rectangle().fill(color.opacity(0.08)))
                .frame(width: 36, height: 36)
            Image(systemName: habit.iconName)
                .font(.system(size: 14))
                .foregroundStyle(isMet ? color : color.opacity(0.7))
        }
        .shadow(color: isMet ? color.opacity(0.4) : .clear, radius: 6)
    }

    @ViewBuilder
    private var targetBadge: some View {
        let label: String = {
            switch habit.kind {
            case .binary:
                return habit.frequency.displayName.uppercased()
            case .quantity, .duration, .count:
                let unit = habit.unit ?? ""
                return "\(format(target))\(unit.isEmpty ? "" : " \(unit)") · \(habit.frequency.displayName)".uppercased()
            }
        }()
        Text(label)
            .font(Theme.Typography.label)
            .tracking(Theme.Tracking.tight)
            .foregroundStyle(Theme.Colors.textDim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
    }

    private var progressLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if habit.kind == .binary {
                    Text(isMet ? "Done today" : "Not done")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isMet ? color : Theme.Colors.textDim)
                } else {
                    let unit = habit.unit ?? ""
                    Text("\(format(progress)) / \(format(target))\(unit.isEmpty ? "" : " \(unit)")")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isMet ? color : Theme.Colors.text)
                }
                Spacer()
            }
            ProgressBar(progress: ratio, color: color)
                .frame(height: 3)
                .frame(maxWidth: 240)
        }
    }

    private var streakChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 9))
            Text("\(streak)")
                .font(Theme.Typography.caption)
        }
        .foregroundStyle(streak > 0 ? Theme.Colors.amber : Theme.Colors.textDim)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
    }

    @ViewBuilder
    private var actionButton: some View {
        if habit.kind == .binary {
            Button {
                Task { await toggleBinary() }
            } label: {
                Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isMet ? color : Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                quickLogValue = ""
                showQuickLog = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Quick log popover

    private var quickLogPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("LOG \(habit.title.uppercased())")
                .hudLabel(tracking: Theme.Tracking.wide, color: color)

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(quickPresets, id: \.self) { preset in
                    Button {
                        Task {
                            await appState.logHabitEntry(habitId: habit.id, value: preset)
                            showQuickLog = false
                        }
                    } label: {
                        Text("+\(format(preset))\(habit.unit.map { " \($0)" } ?? "")")
                            .font(Theme.Typography.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                TextField("custom", text: $quickLogValue)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Colors.bg2)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
                    .frame(width: 100)
                Button("LOG") {
                    if let n = Double(quickLogValue.replacingOccurrences(of: ",", with: ".")), n > 0 {
                        Task {
                            await appState.logHabitEntry(habitId: habit.id, value: n)
                            showQuickLog = false
                        }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(Double(quickLogValue.replacingOccurrences(of: ",", with: ".")) == nil)

                Button("FILL DAY") {
                    Task {
                        await appState.completeHabitToday(habitId: habit.id)
                        showQuickLog = false
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(Theme.Spacing.md)
        .frame(minWidth: 320)
        .background(Theme.Colors.bg1)
    }

    /// Smart defaults for the +N quick presets, by unit.
    private var quickPresets: [Double] {
        let unit = (habit.unit ?? "").lowercased()
        let target = habit.dailyTarget
        if unit == "ml" { return [250, 500, 750] }
        if unit == "min" || unit == "minutes" { return [5, 15, 30] }
        if unit == "g" || unit == "grams" { return [10, 25, 50] }
        if unit == "pages" { return [1, 5, 10] }
        if unit == "reps" || unit == "times" { return [1, 5, 10] }
        if unit == "steps" { return [1000, 2500, 5000] }
        // Generic: roughly 25/50/100% of target
        let q = max(1, (target / 4).rounded())
        return [q, q * 2, q * 4]
    }

    // MARK: - Actions

    private func toggleBinary() async {
        if isMet {
            // Unmet: remove today's entries.
            let today = Calendar.current.startOfDay(for: Date())
            let next = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
            let toRemove = habit.entries.filter { $0.date >= today && $0.date < next }
            for e in toRemove {
                await appState.deleteHabitEntry(habitId: habit.id, entryId: e.id)
            }
        } else {
            await appState.completeHabitToday(habitId: habit.id)
        }
    }

    private func archive() async {
        var updated = habit
        updated.isArchived = true
        await appState.updateHabit(updated)
    }

    private func unarchive() async {
        var updated = habit
        updated.isArchived = false
        await appState.updateHabit(updated)
    }

    private func delete() async {
        await appState.deleteHabit(habit)
    }

    private func format(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.1f", n)
    }
}
