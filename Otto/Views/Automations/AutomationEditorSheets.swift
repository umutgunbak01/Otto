import SwiftUI

// MARK: - Scheduled task editor

/// Create/edit sheet for a recurring task. Modeled on `HabitCreatorSheet`:
/// header / scrolling form / footer, same field primitives.
struct ScheduledTaskEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existing: ScheduledTask?

    @State private var name: String
    @State private var prompt: String
    @State private var frequencyChoice: FrequencyChoice
    @State private var weekdays: Set<Habit.Weekday>
    @State private var monthDay: Int
    @State private var time: Date
    @State private var catchUpPolicy: ScheduledTask.CatchUpPolicy
    @State private var notifyOnCompletion: Bool
    @State private var autoApproveTools: Bool
    @State private var isEnabled: Bool

    enum FrequencyChoice: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekdays = "Weekdays"
        case custom = "Custom days"
        case monthly = "Monthly"
        var id: String { rawValue }
    }

    init(existing: ScheduledTask?, draftName: String? = nil, draftPrompt: String? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? draftName ?? "")
        _prompt = State(initialValue: existing?.prompt ?? draftPrompt ?? "")
        _catchUpPolicy = State(initialValue: existing?.catchUpPolicy ?? .runASAP)
        _notifyOnCompletion = State(initialValue: existing?.notifyOnCompletion ?? true)
        _autoApproveTools = State(initialValue: existing?.autoApproveTools ?? false)
        _isEnabled = State(initialValue: existing?.isEnabled ?? true)

        let schedule = existing?.schedule ?? TaskSchedule()
        let workweek: Set<Habit.Weekday> = [.mon, .tue, .wed, .thu, .fri]
        switch schedule.days {
        case .daily:
            _frequencyChoice = State(initialValue: .daily)
            _weekdays = State(initialValue: workweek)
            _monthDay = State(initialValue: 1)
        case .weekdays(let set):
            _frequencyChoice = State(initialValue: set == workweek ? .weekdays : .custom)
            _weekdays = State(initialValue: set)
            _monthDay = State(initialValue: 1)
        case .monthly(let day):
            _frequencyChoice = State(initialValue: .monthly)
            _weekdays = State(initialValue: workweek)
            _monthDay = State(initialValue: day)
        }

        var comps = DateComponents()
        comps.hour = schedule.hour
        comps.minute = schedule.minute
        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(frequencyChoice == .custom && weekdays.isEmpty)
    }

    private var builtSchedule: TaskSchedule {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let days: TaskSchedule.Days
        switch frequencyChoice {
        case .daily:    days = .daily
        case .weekdays: days = .weekdays([.mon, .tue, .wed, .thu, .fri])
        case .custom:   days = weekdays.isEmpty ? .daily : .weekdays(weekdays)
        case .monthly:  days = .monthly(day: monthDay)
        }
        return TaskSchedule(days: days, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    field(label: "Name") {
                        textField($name, placeholder: "e.g. Morning digest")
                    }

                    field(label: "Prompt — what should Otto do?") {
                        promptEditor
                    }

                    field(label: "Frequency") {
                        Picker("", selection: $frequencyChoice) {
                            ForEach(FrequencyChoice.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    switch frequencyChoice {
                    case .daily, .weekdays:
                        EmptyView()
                    case .custom:
                        weekdayPicker
                    case .monthly:
                        Stepper(value: $monthDay, in: 1...31) {
                            Text("On the \(TaskSchedule.ordinal(monthDay))")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.text)
                        }
                        Text("Months without a \(TaskSchedule.ordinal(monthDay)) run on their last day.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textDim)
                            .opacity(monthDay > 28 ? 1 : 0)
                    }

                    field(label: "Time") {
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                    }

                    field(label: "If the Mac was off or asleep at that time") {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $catchUpPolicy) {
                                ForEach(ScheduledTask.CatchUpPolicy.allCases, id: \.self) { p in
                                    Text(p.displayName).tag(p)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Text(catchUpPolicy == .runASAP
                                 ? "Runs at the first opportunity once Otto is open — at most once per day."
                                 : "Only runs on the scheduled day; a fully missed day waits for the next occurrence.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                    }

                    Toggle(isOn: $notifyOnCompletion) {
                        Text("Notify when a run finishes")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $autoApproveTools) {
                            Text("Auto-approve tool requests")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.text)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Text("Unattended runs can't wait for you — approve every tool permission request this task's runs make (relevant on the Hermes backend). Applies only to this task.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if existing != nil {
                        Toggle(isOn: $isEnabled) {
                            Text("Enabled")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.text)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Theme.Colors.bg1)
    }

    private var header: some View {
        HStack {
            Text(existing == nil ? "New Recurring Task" : "Edit Recurring Task")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.text)
            Spacer()
            Button { dismiss() } label: {
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
            if let existing, let due = existing.nextDueAt, isEnabled {
                Text("Next run \(AutomationsView.nextRunText(due))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textDim)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(GhostButtonStyle())
            Button(existing == nil ? "Create" : "Save") {
                Task { await save() }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(AccentButtonStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    private var promptEditor: some View {
        TextEditor(text: $prompt)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.text)
            .scrollContentBackground(.hidden)
            .padding(Theme.Spacing.sm)
            .frame(minHeight: 96, maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
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
                        .foregroundStyle(isOn ? Theme.Colors.accentText : Theme.Colors.textDim)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isOn ? Theme.Colors.selectTint : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isOn ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textDim)
            content()
        }
    }

    private func textField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.text)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
    }

    private func save() async {
        guard canSave else { return }
        var task = existing ?? ScheduledTask(name: "", prompt: "")
        task.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        task.schedule = builtSchedule
        task.catchUpPolicy = catchUpPolicy
        task.notifyOnCompletion = notifyOnCompletion
        task.autoApproveTools = autoApproveTools
        task.isEnabled = isEnabled
        await appState.saveScheduledTaskEdits(task)
        dismiss()
    }
}

// MARK: - Saved prompt editor

struct SavedPromptEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existing: SavedPrompt?

    @State private var name: String
    @State private var prompt: String

    init(existing: SavedPrompt?, draftPrompt: String? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _prompt = State(initialValue: existing?.prompt ?? draftPrompt ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(existing == nil ? "New Saved Prompt" : "Edit Saved Prompt")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.lg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Colors.border).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                    TextField("e.g. Weekly review", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.bgInput)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                    TextEditor(text: $prompt)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Spacing.sm)
                        .frame(minHeight: 140, maxHeight: 260)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.bgInput)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                }
            }
            .padding(Theme.Spacing.lg)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(GhostButtonStyle())
                Button(existing == nil ? "Save" : "Save Changes") {
                    Task { await save() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(Theme.Spacing.lg)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Colors.border).frame(height: 1)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.Colors.bg1)
    }

    private func save() async {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if var updated = existing {
            updated.name = trimmedName
            updated.prompt = trimmedPrompt
            await appState.updateSavedPrompt(updated)
        } else {
            await appState.addSavedPrompt(SavedPrompt(name: trimmedName, prompt: trimmedPrompt))
        }
        dismiss()
    }
}
