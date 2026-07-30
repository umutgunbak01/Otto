import SwiftUI

struct HabitRowView: View {
    @Environment(AppState.self) private var appState
    let habit: Habit
    var isSelected: Bool = false
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var showQuickLog = false
    @State private var quickLogValue: String = ""

    // Layout constants shared with HabitListView's week-letter header so the
    // M–S letters sit exactly above the dot columns.
    static let dotSize: CGFloat = 14
    static let dotSpacing: CGFloat = 6
    static let streakChipWidth: CGFloat = 44
    static let actionSize: CGFloat = 28
    /// Distance from the row's trailing edge to the right edge of the
    /// week-dot block: row padding + action button + gap + streak chip + gap.
    static let weekTrailingInset: CGFloat =
        Theme.Spacing.md + actionSize + Theme.Spacing.md + streakChipWidth + Theme.Spacing.md

    private var progress: Double { habit.progress(on: Date()) }
    private var target: Double { max(1, habit.dailyTarget) }
    private var ratio: Double { min(1, progress / target) }
    private var isMet: Bool { habit.isMet(on: Date()) }
    private var streak: Int { habit.currentStreak() }
    private var color: Color { habit.colorTag.color }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            OttoSquare(systemImage: habit.iconName, color: color)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(habit.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    freqChip
                }
                statusLine
            }

            Spacer(minLength: Theme.Spacing.sm)

            weekDots

            streakChip

            actionButton
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Theme.Spacing.md)
        .background(
            // Quiet list row (mockup .lrow) — no border, wash on hover,
            // teal tint while the detail popup is open.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered ? Theme.Colors.panel : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
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

    /// Compact frequency chip — mono uppercase outline (TagChipView style).
    private var freqChip: some View {
        Text(freqLabel)
            .font(.system(size: 8.5, weight: .regular, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
    }

    private var freqLabel: String {
        switch habit.frequency {
        case .daily:
            return "DAILY"
        case .weekdays(let days):
            if days.isEmpty || days.count == 7 { return "DAILY" }
            return "\(days.count)×/WEEK"
        case .weeklyCount(let n):
            return "\(n)×/WEEK"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if habit.kind == .binary {
            Text(isMet ? "Done today" : "Not done")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isMet ? color : Theme.Colors.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                let unit = habit.unit ?? ""
                Text("\(format(progress)) / \(format(target))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isMet ? color : Theme.Colors.tertiaryText)
                ProgressBar(progress: ratio, color: color)
                    .frame(height: 3)
                    .frame(maxWidth: 200)
            }
        }
    }

    // MARK: - Week dots

    /// The 7 dates of the current ISO week (Mon–Sun), computed once per row.
    private var weekDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let daysFromMonday = (cal.component(.weekday, from: today) + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    private var weekDots: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let created = cal.startOfDay(for: habit.createdAt)
        return HStack(spacing: Self.dotSpacing) {
            ForEach(weekDays, id: \.self) { day in
                dot(for: day, today: today, created: created)
            }
        }
    }

    private func dot(for day: Date, today: Date, created: Date) -> some View {
        let isToday = day == today

        return Group {
            if habit.isMet(on: day) {
                Circle().fill(color)
            } else if isToday {
                Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5)
            } else if day < today, day >= created, habit.isRequired(on: day) {
                // Missed: required, in the past, not done.
                Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5)
            } else {
                // Upcoming, off-schedule, or pre-creation days stay faint.
                Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1.5)
            }
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
        .overlay {
            if isToday {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .padding(-3)
            }
        }
    }

    // MARK: - Streak + action

    private var streakChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 9))
            Text("\(streak)d")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(streak > 0 ? Theme.Colors.amber : Theme.Colors.tertiaryText)
        .frame(width: Self.streakChipWidth, alignment: .trailing)
    }

    /// 28pt rounded-square quick action — checkmark in the teal-wash style
    /// when today is met, plus otherwise. Binary habits toggle directly;
    /// quantified habits keep the quick-log popover.
    private var actionButton: some View {
        Button {
            if habit.kind == .binary {
                Task { await toggleBinary() }
            } else {
                quickLogValue = ""
                showQuickLog = true
            }
        } label: {
            Image(systemName: isMet ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isMet ? Theme.Colors.cyan : Theme.Colors.textDim)
                .frame(width: Self.actionSize, height: Self.actionSize)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(isMet ? Theme.Colors.tintTeal : Theme.Colors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(
                            isMet ? Theme.Colors.cyan.opacity(0.35) : Theme.Colors.border,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick log popover

    private var quickLogPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Log \(habit.title)")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.text)

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(quickPresets, id: \.self) { preset in
                    Button {
                        Task {
                            await appState.logHabitEntry(habitId: habit.id, value: preset)
                            showQuickLog = false
                        }
                    } label: {
                        Text("+\(format(preset))\(habit.unit.map { " \($0)" } ?? "")")
                            .font(Theme.Typography.monoCaption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                TextField("custom", text: $quickLogValue)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.bgInput)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .frame(width: 100)
                Button {
                    if let n = Double(quickLogValue.replacingOccurrences(of: ",", with: ".")), n > 0 {
                        Task {
                            await appState.logHabitEntry(habitId: habit.id, value: n)
                            showQuickLog = false
                        }
                    }
                } label: {
                    Text("Log")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(Double(quickLogValue.replacingOccurrences(of: ",", with: ".")) == nil)

                Button {
                    Task {
                        await appState.completeHabitToday(habitId: habit.id)
                        showQuickLog = false
                    }
                } label: {
                    Text("Fill day")
                        .font(.system(size: 12, weight: .medium))
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
