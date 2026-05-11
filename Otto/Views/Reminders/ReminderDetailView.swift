import SwiftUI

struct ReminderDetailView: View {
    @Environment(AppState.self) private var appState
    let reminder: Reminder
    var onClose: (() -> Void)? = nil

    @State private var title: String = ""
    @State private var reminderDate: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)

            OttoDivider()

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Status indicator + Title
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        // Status icon
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.12))
                                .frame(width: 32, height: 32)

                            Image(systemName: statusIcon)
                                .font(.system(size: 14))
                                .foregroundStyle(statusColor)
                        }
                        .padding(.top, 2)

                        // Title
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            TextField("Reminder", text: $title)
                                .font(.system(size: 24, weight: .semibold))
                                .textFieldStyle(.plain)
                                .strikethrough(reminder.isTriggered, color: Theme.Colors.secondaryText)
                                .foregroundStyle(reminder.isTriggered ? Theme.Colors.secondaryText : Theme.Colors.text)

                            // Status label
                            Text(statusLabel)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(statusColor)
                        }
                    }

                    // Date/Time section - Todoist style
                    VStack(alignment: .leading, spacing: 0) {
                        if !reminder.isTriggered {
                            ReminderDatePicker(date: $reminderDate)
                        } else {
                            // Show the date but not editable
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .frame(width: 20)

                                Text(formatDateOnly(reminder.reminderDate))
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Colors.secondaryText)

                                Text(formatTimeOnly(reminder.reminderDate))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.tertiaryText)

                                Spacer()
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.borderSubtle.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
                    )

                    // Triggered info
                    if reminder.isTriggered {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Colors.personal)

                            Text("This reminder has been completed")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)

                            Spacer()

                            // Restore button
                            Button {
                                Task { await restoreReminder() }
                            } label: {
                                Text("Restore")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .fill(Theme.Colors.personal.opacity(0.05))
                        )
                    }

                    // Created info
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        Text("Created \(timeAgo(reminder.createdAt))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .onAppear { loadReminder() }
        .onChange(of: reminder.id) { loadReminder() }
        .onChange(of: title) { saveChanges() }
        .onChange(of: reminderDate) { saveChanges() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Close button (moved to left to avoid misclicks with delete)
            if onClose != nil {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
            }

            // Breadcrumb
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "bell")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.priorityHigh)
                Text("Reminders")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(reminder.title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Mark as done (if not triggered)
            if !reminder.isTriggered {
                Button {
                    Task { await appState.markReminderTriggered(reminder) }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Done")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(Theme.Colors.personal)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.personal.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
            }

            // Convert type
            ConvertTypeMenu(currentType: .reminder) { newType in
                Task { await appState.convertReminder(reminder, to: newType) }
            }

            // Delete
            Button {
                Task { await appState.deleteReminder(reminder) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var statusIcon: String {
        if reminder.isTriggered {
            return "checkmark"
        } else if reminder.isPast {
            return "exclamationmark"
        } else {
            return "bell.fill"
        }
    }

    private var statusColor: Color {
        if reminder.isTriggered {
            return Theme.Colors.personal
        } else if reminder.isPast {
            return Theme.Colors.priorityUrgent
        } else {
            return Theme.Colors.priorityHigh
        }
    }

    private var statusLabel: String {
        if reminder.isTriggered {
            return "Completed"
        } else if reminder.isPast {
            return "Overdue"
        } else {
            return "Upcoming"
        }
    }

    private func loadReminder() {
        title = reminder.title
        reminderDate = reminder.reminderDate
    }

    private func saveChanges() {
        // Note: We'd need to add an updateReminder method to AppState
        // For now, this is a placeholder
    }

    private func restoreReminder() async {
        // Would need to add this to AppState
    }

    private func formatDateOnly(_ date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay == today {
            return "Today"
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return "Tomorrow"
        } else if dateDay == calendar.date(byAdding: .day, value: -1, to: today) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date)
        }
    }

    private func formatTimeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }
}

#Preview {
    ReminderDetailView(reminder: Reminder(
        title: "Call mom",
        reminderDate: Date().addingTimeInterval(3600)
    ))
    .environment(AppState())
    .frame(width: 500, height: 600)
}
