import SwiftUI

struct TodoRowView: View {
    @Environment(AppState.self) private var appState
    let todo: Todo
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isCheckboxHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Checkbox - clickable to complete
            Button {
                Task {
                    await appState.toggleTodo(todo)
                }
            } label: {
                // Rounded-square check (mockup .cb) — teal wash when done.
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5)
                        .strokeBorder(
                            todo.isCompleted
                                ? Theme.Colors.cyan.opacity(0.45)
                                : (isCheckboxHovered ? Theme.Colors.cyan.opacity(0.55) : Color.white.opacity(0.22)),
                            lineWidth: 1.5
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 5.5)
                                .fill(todo.isCompleted ? Theme.Colors.tintTeal : Color.clear)
                        )
                        .frame(width: 16, height: 16)

                    if todo.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Colors.cyan)
                    } else if isCheckboxHovered {
                        // Show checkmark preview on hover
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Theme.Colors.cyan.opacity(0.6))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isCheckboxHovered)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCheckboxHovered = hovering
            }
            .padding(.top, 2)

            // Content - clickable to select
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(todo.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .strikethrough(todo.isCompleted, color: Theme.Colors.secondaryText)
                        .foregroundStyle(todo.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.text)
                        .lineLimit(2)

                    // Description (if exists)
                    if !todo.description.isEmpty {
                        Text(todo.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }

                    // Metadata row (date + labels + sub-tasks + Todoist badge)
                    HStack(spacing: 6) {
                        if let dueDate = todo.dueDate {
                            HStack(spacing: 4) {
                                Image(systemName: isOverdue(dueDate) ? "calendar.badge.exclamationmark" : "calendar")
                                    .font(.system(size: 10))
                                Text(formatDate(dueDate))
                                    .font(Theme.Typography.monoCaption)

                                // Show time if it has a specific time
                                if hasSpecificTime(dueDate) {
                                    Text(formatTime(dueDate))
                                        .font(Theme.Typography.monoCaption)
                                }
                            }
                            .foregroundStyle(dateColor(dueDate))
                        }

                        // Label chips (first 2 + overflow count)
                        let tags = appState.tags(for: todo.domainTagIds)
                        ForEach(tags.prefix(2)) { tag in
                            TagChipView(tag: tag, isCompact: true)
                        }
                        if tags.count > 2 {
                            Text("+\(tags.count - 2)")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.textDim)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.Colors.hoverTint)
                                )
                        }

                        // Sub-task progress
                        if !todo.subTasks.isEmpty {
                            let completed = todo.subTasks.filter(\.isCompleted).count
                            HStack(spacing: 3) {
                                Image(systemName: "checklist")
                                    .font(.system(size: 10))
                                Text("\(completed)/\(todo.subTasks.count)")
                                    .font(Theme.Typography.monoCaption)
                            }
                            .foregroundStyle(completed == todo.subTasks.count ? Theme.Colors.green : Theme.Colors.tertiaryText)
                        }

                        // Todoist project badge
                        if let projectName = todo.todoistProjectName {
                            Text(projectName)
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.accentText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.Colors.selectTint)
                                )
                        } else if todo.todoistId != nil {
                            Text("Todoist")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.accentText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.Colors.selectTint)
                                )
                        }
                    }
                }

                Spacer()

                // Right side - Category/Priority tag
                HStack(spacing: Theme.Spacing.sm) {
                    // Priority flag (mockup .pflag — outline, colored)
                    if todo.priority == .high || todo.priority == .urgent {
                        Image(systemName: "flag")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(priorityColor)
                    }

                    // Hover actions
                    if isHovered {
                        HStack(spacing: Theme.Spacing.xs) {
                            // Convert type menu
                            ConvertTypeMenuCompact(currentType: .todo) { newType in
                                Task { await appState.convertTodo(todo, to: newType) }
                            }

                            // Delete
                            Button {
                                Task { await appState.deleteTodo(todo) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect?()
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, Theme.Spacing.md)
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

    private var checkboxColor: Color {
        if todo.isCompleted {
            return Theme.Colors.secondaryText
        }
        return priorityColor
    }

    private var priorityColor: Color {
        switch todo.priority {
        case .urgent: return Theme.Colors.priorityUrgent
        case .high: return Theme.Colors.priorityHigh
        case .medium: return Theme.Colors.priorityMedium
        case .low: return Theme.Colors.priorityLow
        }
    }

    private func isOverdue(_ date: Date) -> Bool {
        date < Date() && !todo.isCompleted
    }

    private func dateColor(_ date: Date) -> Color {
        if todo.isCompleted {
            return Theme.Colors.tertiaryText
        }
        if isOverdue(date) {
            return Theme.Colors.priorityUrgent
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay == today {
            return Theme.Colors.personal // Green for today
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return Theme.Colors.priorityHigh // Orange for tomorrow
        }

        return Theme.Colors.secondaryText
    }

    private func hasSpecificTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        // If time is not midnight, assume it has a specific time
        return !(hour == 0 && minute == 0)
    }

    private func formatDate(_ date: Date) -> String {
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

#Preview {
    VStack(spacing: 0) {
        TodoRowView(todo: Todo(title: "Find a contact for Sagopa", dueDate: Date().addingTimeInterval(86400), priority: .medium))
        TodoRowView(todo: Todo(title: "Set time to visit HubX", dueDate: Date(), priority: .high), isSelected: true)
        TodoRowView(todo: Todo(title: "Send Nina contracts from Startup Program", description: "Check from LightDash", dueDate: Date().addingTimeInterval(-86400), priority: .urgent))
        TodoRowView(todo: Todo(title: "Review meeting notes with Nina", dueDate: Date().addingTimeInterval(-86400), priority: .medium))
        TodoRowView(todo: Todo(title: "Completed task", isCompleted: true))
    }
    .environment(AppState())
    .frame(width: 400)
    .padding()
    #if os(macOS)
    .background(Theme.Colors.background)
    #else
    .background(Color(uiColor: .systemBackground))
    #endif
}
