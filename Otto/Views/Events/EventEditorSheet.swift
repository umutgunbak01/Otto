import SwiftUI

/// Create or edit an Event. Pass `event` to edit; nil to create.
struct EventEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let event: Event?

    @State private var name: String
    @State private var type: EventType
    @State private var location: String
    @State private var status: EventStatus
    @State private var hasDates: Bool
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var budgetText: String
    @State private var notes: String

    private var isEditing: Bool { event != nil }

    init(event: Event?) {
        self.event = event
        _name = State(initialValue: event?.name ?? "")
        _type = State(initialValue: event?.type ?? .unknown)
        _location = State(initialValue: event?.location ?? "")
        _status = State(initialValue: event?.status ?? .considering)
        let start = event?.startDate
        _hasDates = State(initialValue: start != nil)
        _startDate = State(initialValue: start ?? Date())
        let end = event?.endDate
        _hasEndDate = State(initialValue: end != nil && end != start)
        _endDate = State(initialValue: end ?? (start ?? Date()))
        _budgetText = State(initialValue: MoneyField.string(from: event?.budgetAmount))
        _notes = State(initialValue: event?.notes ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    FormField(label: "NAME") {
                        FormText(text: $name, placeholder: "e.g. AI Engineer Summit")
                    }

                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        FormField(label: "TYPE") {
                            Picker("", selection: $type) {
                                ForEach(EventType.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.Colors.cyan)
                        }
                        FormField(label: "STATUS") {
                            Picker("", selection: $status) {
                                ForEach(EventStatus.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.Colors.cyan)
                        }
                    }

                    FormField(label: "CITY") {
                        FormText(text: $location, placeholder: "e.g. Paris")
                    }

                    // Dates
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Toggle(isOn: $hasDates) {
                            Text("Scheduled").font(Theme.Typography.body).foregroundStyle(Theme.Colors.text)
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.Colors.cyan)

                        if hasDates {
                            DatePicker("Start", selection: $startDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .font(Theme.Typography.body)

                            Toggle(isOn: $hasEndDate) {
                                Text("Multi-day").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textDim)
                            }
                            .toggleStyle(.switch)
                            .tint(Theme.Colors.cyan)

                            if hasEndDate {
                                DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .font(Theme.Typography.body)
                            }
                        }
                    }
                    .padding(Theme.Spacing.sm)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1))

                    FormField(label: "BUDGET ($, optional)") {
                        FormText(text: $budgetText, placeholder: "e.g. 10000")
                    }

                    FormField(label: "NOTES") {
                        FormTextEditor(text: $notes, placeholder: "Goals, who to meet, logistics…")
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 600)
        .background(Theme.Colors.bg1)
    }

    private var header: some View {
        HStack {
            Text(isEditing ? "EDIT EVENT" : "NEW EVENT")
                .hudLabel(tracking: Theme.Tracking.xxwide, color: Theme.Colors.cyan)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("DELETE", role: .destructive) {
                    if let event { Task { await appState.deleteEvent(event); dismiss() } }
                }
                .buttonStyle(GhostButtonStyle())
                .foregroundStyle(Theme.Colors.red)
            }
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Button(isEditing ? "SAVE" : "CREATE") { Task { await save() } }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let start: Date? = hasDates ? startDate : nil
        let end: Date? = (hasDates && hasEndDate) ? endDate : nil

        if let existing = event {
            var updated = existing
            updated.name = trimmedName
            updated.type = type
            updated.location = location.trimmingCharacters(in: .whitespaces)
            updated.status = status
            updated.startDate = start
            updated.endDate = end
            updated.budgetAmount = MoneyField.amount(from: budgetText)
            updated.notes = notes
            await appState.updateEvent(updated)
        } else {
            let new = Event(
                name: trimmedName,
                type: type,
                location: location.trimmingCharacters(in: .whitespaces),
                startDate: start,
                endDate: end,
                status: status,
                budgetAmount: MoneyField.amount(from: budgetText),
                notes: notes
            )
            await appState.addEvent(new)
        }
        dismiss()
    }
}
