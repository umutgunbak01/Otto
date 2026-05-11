import SwiftUI

struct DaySection: View {
    @Environment(AppState.self) private var appState
    let date: Date
    let todos: [Todo]
    let events: [CalendarEvent]
    var onAddTask: (() -> Void)? = nil
    var onSelectTodo: ((Todo) -> Void)? = nil
    var selectedTodoId: UUID? = nil

    @State private var isCollapsed: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            // Content (collapsible)
            if !isCollapsed {
                VStack(spacing: 0) {
                    // Calendar events first
                    ForEach(events) { event in
                        CalendarEventRowView(event: event)
                    }

                    // Then todos
                    ForEach(todos) { todo in
                        TodoRowView(
                            todo: todo,
                            isSelected: selectedTodoId == todo.id
                        ) {
                            onSelectTodo?(todo)
                        }
                    }

                    // Add task button
                    if let onAddTask = onAddTask {
                        addTaskButton(action: onAddTask)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCollapsed.toggle()
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(formattedHeader)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(headerColor)

                if isToday {
                    Text("Today")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.personal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.personal.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                // Item count badge
                let totalItems = todos.count + events.count
                if totalItems > 0 {
                    Text("\(totalItems)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Collapse indicator
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isHovered ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Add Task Button

    private func addTaskButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)

                Text("Add task")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    // MARK: - Helpers

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(date)
    }

    private var headerColor: Color {
        if isToday {
            return Theme.Colors.personal
        } else if isTomorrow {
            return Theme.Colors.priorityHigh
        }
        return Theme.Colors.text
    }

    private var formattedHeader: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay == today {
            return formatDateWithWeekday(date)
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return formatDateWithWeekday(date) + " \u{2022} Tomorrow"
        } else {
            return formatDateWithWeekday(date)
        }
    }

    private func formatDateWithWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM \u{2022} EEEE"
        return formatter.string(from: date)
    }
}

// MARK: - Overdue Section

struct OverdueSection: View {
    @Environment(AppState.self) private var appState
    let overdueTodos: [Todo]
    let noDateTodos: [Todo]
    var onSelectTodo: ((Todo) -> Void)? = nil
    var selectedTodoId: UUID? = nil

    @State private var isOverdueCollapsed: Bool = false
    @State private var isNoDateCollapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Overdue section
            if !overdueTodos.isEmpty {
                overdueHeader

                if !isOverdueCollapsed {
                    ForEach(overdueTodos) { todo in
                        TodoRowView(
                            todo: todo,
                            isSelected: selectedTodoId == todo.id
                        ) {
                            onSelectTodo?(todo)
                        }
                    }
                }
            }

            // No Date section
            if !noDateTodos.isEmpty {
                noDateHeader

                if !isNoDateCollapsed {
                    ForEach(noDateTodos) { todo in
                        TodoRowView(
                            todo: todo,
                            isSelected: selectedTodoId == todo.id
                        ) {
                            onSelectTodo?(todo)
                        }
                    }
                }
            }
        }
    }

    private var overdueHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOverdueCollapsed.toggle()
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.priorityUrgent)

                Text("Overdue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.priorityUrgent)

                Spacer()

                Text("\(overdueTodos.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Image(systemName: isOverdueCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noDateHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isNoDateCollapsed.toggle()
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text("No Date")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                Text("\(noDateTodos.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Image(systemName: isNoDateCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Day Group Model

struct DayGroup: Identifiable {
    let id: Date
    let date: Date
    var todos: [Todo]
    var events: [CalendarEvent]

    init(date: Date, todos: [Todo] = [], events: [CalendarEvent] = []) {
        self.id = Calendar.current.startOfDay(for: date)
        self.date = date
        self.todos = todos
        self.events = events
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 0) {
            OverdueSection(
                overdueTodos: [
                    Todo(title: "Overdue task 1", dueDate: Date().addingTimeInterval(-86400), priority: .high),
                    Todo(title: "Overdue task 2", dueDate: Date().addingTimeInterval(-172800), priority: .urgent)
                ],
                noDateTodos: [
                    Todo(title: "Task without date"),
                    Todo(title: "Another undated task")
                ]
            )

            Divider()
                .padding(.horizontal, Theme.Spacing.md)

            DaySection(
                date: Date(),
                todos: [
                    Todo(title: "Review Startup Program Applications", dueDate: Date(), priority: .medium)
                ],
                events: [
                    CalendarEvent(
                        googleEventId: "1",
                        calendarId: "primary",
                        title: "Standup with Alice",
                        startTime: Date(),
                        endTime: Date().addingTimeInterval(1800)
                    ),
                    CalendarEvent(
                        googleEventId: "2",
                        calendarId: "primary",
                        title: "Vendor Sync",
                        startTime: Date().addingTimeInterval(3600),
                        endTime: Date().addingTimeInterval(5400)
                    )
                ],
                onAddTask: { print("Add task") }
            )

            Divider()
                .padding(.horizontal, Theme.Spacing.md)

            DaySection(
                date: Date().addingTimeInterval(86400),
                todos: [],
                events: [],
                onAddTask: { print("Add task") }
            )
        }
    }
    .environment(AppState())
    .frame(width: 450, height: 600)
    #if os(macOS)
    .background(Theme.Colors.background)
    #else
    .background(Color(uiColor: .systemBackground))
    #endif
}
