import SwiftUI

struct HabitCreatorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var kind: Habit.Kind = .binary
    @State private var unit: String = ""
    @State private var dailyTarget: String = "1"
    @State private var frequencyChoice: FrequencyChoice = .daily
    @State private var weekdays: Set<Habit.Weekday> = [.mon, .tue, .wed, .thu, .fri]
    @State private var weeklyCount: Int = 3
    @State private var category: Habit.Category = .custom
    @State private var iconName: String = "checkmark.circle"
    @State private var colorTag: Habit.ColorTag = .cyan

    enum FrequencyChoice: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekdays = "Weekdays"
        case weekly = "Weekly target"
        var id: String { rawValue }
    }

    private var canSave: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if kind != .binary, Double(targetString) == nil { return false }
        return true
    }

    private var targetString: String {
        dailyTarget.replacingOccurrences(of: ",", with: ".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    templatesSection
                    Divider().background(Theme.Colors.border)
                    formSection
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 600)
        .background(Theme.Colors.bg1)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text("NEW HABIT")
                .hudLabel(tracking: Theme.Tracking.xxwide, color: Theme.Colors.cyan)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Button("CREATE") {
                Task { await save() }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("STARTERS")
                .hudLabel(tracking: Theme.Tracking.wide)
            let cols = [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.sm)]
            LazyVGrid(columns: cols, spacing: Theme.Spacing.sm) {
                ForEach(HabitTemplate.starters) { t in
                    Button {
                        apply(t)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: t.icon)
                                    .foregroundStyle(t.colorTag.color)
                                Text(t.title)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Colors.text)
                            }
                            Text(t.subtitle)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.sm)
                        .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            field(label: "TITLE") {
                textField($title, placeholder: "e.g. Drink water")
            }

            field(label: "NOTES (optional)") {
                textField($notes, placeholder: "What does success look like?")
            }

            field(label: "KIND") {
                Picker("", selection: $kind) {
                    ForEach(Habit.Kind.allCases, id: \.self) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, newKind in
                    if newKind == .binary {
                        dailyTarget = "1"
                        unit = ""
                    } else if dailyTarget == "1" {
                        // Provide a sensible default the user can override.
                        dailyTarget = ""
                    }
                }
            }

            if kind != .binary {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    field(label: "TARGET / DAY") {
                        textField($dailyTarget, placeholder: "e.g. 2500")
                    }
                    field(label: "UNIT") {
                        textField($unit, placeholder: "mL, min, g…")
                    }
                }
            }

            field(label: "FREQUENCY") {
                Picker("", selection: $frequencyChoice) {
                    ForEach(FrequencyChoice.allCases) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch frequencyChoice {
            case .daily:
                EmptyView()
            case .weekdays:
                weekdayPicker
            case .weekly:
                Stepper(value: $weeklyCount, in: 1...7) {
                    Text("\(weeklyCount)× per week")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            field(label: "CATEGORY") {
                Picker("", selection: $category) {
                    ForEach(Habit.Category.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)
            }

            field(label: "COLOR") {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Habit.ColorTag.allCases, id: \.self) { c in
                        Button {
                            colorTag = c
                        } label: {
                            Circle()
                                .fill(c.color)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(c == colorTag ? Theme.Colors.text : .clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach([Habit.Weekday.mon, .tue, .wed, .thu, .fri, .sat, .sun], id: \.self) { d in
                let isOn = weekdays.contains(d)
                Button {
                    if isOn { weekdays.remove(d) } else { weekdays.insert(d) }
                } label: {
                    Text(String(d.shortName.prefix(1)))
                        .font(Theme.Typography.caption)
                        .frame(width: 32, height: 28)
                        .foregroundStyle(isOn ? Theme.Colors.cyan : Theme.Colors.textDim)
                        .background(isOn ? Theme.Colors.cyan.opacity(0.1) : Color.clear)
                        .overlay(Rectangle().stroke(isOn ? Theme.Colors.cyan : Theme.Colors.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).hudLabel(tracking: Theme.Tracking.wide)
            content()
        }
    }

    private func textField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.text)
            .padding(Theme.Spacing.sm)
            .background(Theme.Colors.bg2)
            .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
    }

    // MARK: - Actions

    private func apply(_ t: HabitTemplate) {
        title = t.title
        notes = ""
        kind = t.kind
        unit = t.unit ?? ""
        dailyTarget = t.dailyTarget == t.dailyTarget.rounded()
            ? String(Int(t.dailyTarget))
            : String(t.dailyTarget)
        switch t.frequency {
        case .daily:
            frequencyChoice = .daily
        case .weekdays(let days):
            frequencyChoice = .weekdays
            weekdays = days
        case .weeklyCount(let n):
            frequencyChoice = .weekly
            weeklyCount = n
        }
        category = t.category
        iconName = t.icon
        colorTag = t.colorTag
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let target: Double = {
            if kind == .binary { return 1 }
            return Double(targetString) ?? 1
        }()
        let unitFinal: String? = (kind == .binary || unit.trimmingCharacters(in: .whitespaces).isEmpty)
            ? nil
            : unit.trimmingCharacters(in: .whitespaces)
        let frequency: Habit.Frequency = {
            switch frequencyChoice {
            case .daily: return .daily
            case .weekdays:
                return weekdays.isEmpty ? .daily : .weekdays(weekdays)
            case .weekly:
                return .weeklyCount(weeklyCount)
            }
        }()
        let habit = Habit(
            title: trimmedTitle,
            notes: notes,
            iconName: iconName.isEmpty ? "checkmark.circle" : iconName,
            colorTag: colorTag,
            category: category,
            kind: kind,
            unit: unitFinal,
            dailyTarget: target,
            frequency: frequency
        )
        await appState.addHabit(habit)
        dismiss()
    }
}

// MARK: - Templates

struct HabitTemplate: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let colorTag: Habit.ColorTag
    let kind: Habit.Kind
    let unit: String?
    let dailyTarget: Double
    let frequency: Habit.Frequency
    let category: Habit.Category

    static let starters: [HabitTemplate] = [
        .init(title: "Water", subtitle: "2500 mL / day",
              icon: "drop.fill", colorTag: .cyan,
              kind: .quantity, unit: "mL", dailyTarget: 2500,
              frequency: .daily, category: .health),
        .init(title: "Reading", subtitle: "30 min / day",
              icon: "book", colorTag: .amber,
              kind: .duration, unit: "min", dailyTarget: 30,
              frequency: .daily, category: .learning),
        .init(title: "Workout", subtitle: "3× per week",
              icon: "figure.run", colorTag: .red,
              kind: .binary, unit: nil, dailyTarget: 1,
              frequency: .weeklyCount(3), category: .fitness),
        .init(title: "Steps", subtitle: "10 000 / day",
              icon: "figure.walk", colorTag: .green,
              kind: .count, unit: "steps", dailyTarget: 10000,
              frequency: .daily, category: .fitness),
        .init(title: "Meditate", subtitle: "10 min / day",
              icon: "brain.head.profile", colorTag: .hobby,
              kind: .duration, unit: "min", dailyTarget: 10,
              frequency: .daily, category: .mindfulness),
        .init(title: "No Porn", subtitle: "Daily",
              icon: "shield", colorTag: .green,
              kind: .binary, unit: nil, dailyTarget: 1,
              frequency: .daily, category: .mindfulness),
        .init(title: "Skincare", subtitle: "Daily",
              icon: "sparkles", colorTag: .aiAccent,
              kind: .binary, unit: nil, dailyTarget: 1,
              frequency: .daily, category: .personalCare),
        .init(title: "Brush teeth", subtitle: "2× / day",
              icon: "mouth", colorTag: .cyanDim,
              kind: .count, unit: "times", dailyTarget: 2,
              frequency: .daily, category: .personalCare),
        .init(title: "Vegetables", subtitle: "5 servings / day",
              icon: "leaf", colorTag: .green,
              kind: .count, unit: "servings", dailyTarget: 5,
              frequency: .daily, category: .nutrition),
        .init(title: "Protein", subtitle: "120 g / day",
              icon: "fork.knife", colorTag: .amber,
              kind: .quantity, unit: "g", dailyTarget: 120,
              frequency: .daily, category: .nutrition),
        .init(title: "Sleep", subtitle: "8 hr / night",
              icon: "bed.double", colorTag: .cyanDim,
              kind: .duration, unit: "hr", dailyTarget: 8,
              frequency: .daily, category: .health),
        .init(title: "Journal", subtitle: "Daily",
              icon: "pencil.and.scribble", colorTag: .amber,
              kind: .binary, unit: nil, dailyTarget: 1,
              frequency: .daily, category: .mindfulness),
    ]
}
