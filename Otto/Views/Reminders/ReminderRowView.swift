import SwiftUI

struct ReminderRowView: View {
    @Environment(AppState.self) private var appState
    let reminder: Reminder
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Status square — amber pending, red past due, green done.
            OttoSquare(systemImage: statusIcon, color: statusColor)

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(reminder.isCompleted, color: Theme.Colors.secondaryText)
                    .foregroundStyle(reminder.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.text)
                    .lineLimit(2)

                // Time info
                HStack(spacing: Theme.Spacing.md) {
                    // Time
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(formatTime(reminder.reminderDate))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(Theme.Colors.tertiaryText)

                    // Relative time (only for non-completed)
                    if !reminder.isCompleted {
                        Text(relativeTime(reminder.reminderDate))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(reminder.isPastDue ? Theme.Colors.red : Theme.Colors.textDim)
                    }
                }
            }

            Spacer()

            // Actions (visible on hover or always for touch)
            HStack(spacing: Theme.Spacing.sm) {
                if !reminder.isCompleted && isHovered {
                    Button {
                        Task { await appState.completeReminder(reminder) }
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.personal)
                    }
                    .buttonStyle(.plain)
                }

                if isHovered {
                    // Convert type menu
                    ConvertTypeMenuCompact(currentType: .reminder) { newType in
                        Task { await appState.convertReminder(reminder, to: newType) }
                    }

                    Button {
                        Task { await appState.deleteReminder(reminder) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 10)
        .background(
            // Quiet list row (mockup .lrow) — no border, wash on hover,
            // teal tint when selected.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered ? Theme.Colors.panel : Color.clear)
                )
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var statusIcon: String {
        if reminder.isCompleted {
            return "checkmark"
        } else if reminder.isPastDue {
            return "exclamationmark"
        } else {
            return "bell.fill"
        }
    }

    private var statusColor: Color {
        if reminder.isCompleted {
            return Theme.Colors.green
        } else if reminder.isPastDue {
            return Theme.Colors.red
        } else {
            return Theme.Colors.amber
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSince(Date())

        if interval < 0 {
            // Past
            let absInterval = abs(interval)
            if absInterval < 60 { return "just now" }
            else if absInterval < 3600 { return "\(Int(absInterval / 60))m ago" }
            else if absInterval < 86400 { return "\(Int(absInterval / 3600))h ago" }
            else { return "\(Int(absInterval / 86400))d ago" }
        } else {
            // Future
            if interval < 60 { return "in less than a minute" }
            else if interval < 3600 { return "in \(Int(interval / 60))m" }
            else if interval < 86400 { return "in \(Int(interval / 3600))h" }
            else { return "in \(Int(interval / 86400))d" }
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        ReminderRowView(reminder: Reminder(title: "Call mom", reminderDate: Date().addingTimeInterval(3600)))
        ReminderRowView(reminder: Reminder(title: "Send invoice to client - past due", reminderDate: Date().addingTimeInterval(-3600)))
        ReminderRowView(reminder: Reminder(title: "Done reminder", reminderDate: Date().addingTimeInterval(-7200), isCompleted: true))
    }
    .environment(AppState())
    .padding()
    .frame(width: 400)
}
