import SwiftUI

struct TodoListView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: TodoFilter = .active
    @State private var selectedTodoId: UUID?
    @State private var showingAddTodoForDate: Date?

    enum TodoFilter: String, CaseIterable, Identifiable {
        case active = "Upcoming"
        case completed = "Completed"

        var id: String { rawValue }
    }

    // MARK: - Computed Properties

    private var activeTodos: [Todo] {
        appState.todos.filter { !$0.isCompleted }
    }

    private var completedTodos: [Todo] {
        appState.todos.filter { $0.isCompleted }.sorted { ($0.completedAt ?? Date.distantPast) > ($1.completedAt ?? Date.distantPast) }
    }

    /// Todos that are overdue (past due date, not completed)
    private var overdueTodos: [Todo] {
        let now = Calendar.current.startOfDay(for: Date())
        return activeTodos.filter { todo in
            guard let dueDate = todo.dueDate else { return false }
            return Calendar.current.startOfDay(for: dueDate) < now
        }.sorted { todo1, todo2 in
            guard let d1 = todo1.dueDate, let d2 = todo2.dueDate else { return false }
            return d1 < d2
        }
    }

    /// Todos without a due date
    private var noDateTodos: [Todo] {
        activeTodos.filter { $0.dueDate == nil }.sorted { todo1, todo2 in
            if todo1.priority != todo2.priority {
                return todo1.priority > todo2.priority
            }
            return todo1.createdAt > todo2.createdAt
        }
    }

    /// Flat ordered list of all visible todos for navigation
    private var allVisibleTodos: [Todo] {
        if filter == .completed {
            return completedTodos
        } else {
            var result: [Todo] = []
            result.append(contentsOf: overdueTodos)
            result.append(contentsOf: noDateTodos)
            for group in dayGroups {
                result.append(contentsOf: group.todos)
            }
            return result
        }
    }

    /// Group todos and events by day
    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Get todos with future/today due dates (excluding overdue and no-date)
        let futureTodos = activeTodos.filter { todo in
            guard let dueDate = todo.dueDate else { return false }
            return calendar.startOfDay(for: dueDate) >= today
        }

        // Group todos by day
        var todosByDay: [Date: [Todo]] = [:]
        for todo in futureTodos {
            if let dueDate = todo.dueDate {
                let dayStart = calendar.startOfDay(for: dueDate)
                todosByDay[dayStart, default: []].append(todo)
            }
        }

        // Group calendar events by day
        var eventsByDay: [Date: [CalendarEvent]] = [:]
        for event in appState.calendarEvents {
            // Only show future/today events
            if calendar.startOfDay(for: event.startTime) >= today {
                let dayStart = calendar.startOfDay(for: event.startTime)
                eventsByDay[dayStart, default: []].append(event)
            }
        }

        // Combine all unique days
        var allDays = Set(todosByDay.keys)
        allDays.formUnion(eventsByDay.keys)

        // Add today and next 7 days even if empty (to show "Add task" buttons)
        for dayOffset in 0..<7 {
            if let day = calendar.date(byAdding: .day, value: dayOffset, to: today) {
                allDays.insert(day)
            }
        }

        // Create day groups
        let groups = allDays.sorted().map { date -> DayGroup in
            let todos = (todosByDay[date] ?? []).sorted { todo1, todo2 in
                if todo1.priority != todo2.priority {
                    return todo1.priority > todo2.priority
                }
                // Sort by time if both have specific times
                if let d1 = todo1.dueDate, let d2 = todo2.dueDate {
                    return d1 < d2
                }
                return todo1.createdAt > todo2.createdAt
            }

            let events = (eventsByDay[date] ?? []).sorted { $0.startTime < $1.startTime }

            return DayGroup(date: date, todos: todos, events: events)
        }

        return groups
    }

    private var showDetailPopup: Bool {
        selectedTodoId != nil && appState.todos.contains(where: { $0.id == selectedTodoId })
    }

    var body: some View {
        ZStack {
            // Full-width list (no side panel anymore)
            listPanel
                .frame(maxWidth: .infinity)

            // Popup overlay
            if showDetailPopup {
                // Backdrop
                Theme.Colors.bg1.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTodoId = nil
                        }
                    }
                    .transition(.opacity)

                // Detail popup
                if let todoId = selectedTodoId,
                   let todo = appState.todos.first(where: { $0.id == todoId }) {
                    TodoDetailView(
                        todo: todo,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTodoId = nil
                            }
                        },
                        onNavigatePrevious: previousTodoAction(for: todoId),
                        onNavigateNext: nextTodoAction(for: todoId)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDetailPopup)
        .sheet(item: $showingAddTodoForDate) { date in
            QuickAddTodoSheet(prefilledDate: date)
        }
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            // Handle locate from Home search
            if let itemId = newValue {
                // Check if this is a todo
                if appState.todos.contains(where: { $0.id == itemId }) {
                    selectedTodoId = itemId
                    // Clear the locate request
                    appState.locateItemId = nil
                }
            }
        }
        .onAppear {
            // Handle locate if set before view appeared
            if let itemId = appState.locateItemId,
               appState.todos.contains(where: { $0.id == itemId }) {
                selectedTodoId = itemId
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - Navigation Helpers

    private func previousTodoAction(for currentId: UUID) -> (() -> Void)? {
        let todos = allVisibleTodos
        guard let currentIndex = todos.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return nil }

        return {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTodoId = todos[currentIndex - 1].id
            }
        }
    }

    private func nextTodoAction(for currentId: UUID) -> (() -> Void)? {
        let todos = allVisibleTodos
        guard let currentIndex = todos.firstIndex(where: { $0.id == currentId }),
              currentIndex < todos.count - 1 else { return nil }

        return {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTodoId = todos[currentIndex + 1].id
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header
            header

            OttoDivider()

            // Content
            if filter == .completed {
                completedList
            } else {
                dayGroupedList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("⌬ TO-DOS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(activeTodos.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                // Sync calendar button
                if appState.isCalendarConnected {
                    Button {
                        Task { await appState.syncCalendarEvents() }
                    } label: {
                        if appState.isLoadingCalendar {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Sync Calendar")
                    #endif
                    .disabled(appState.isLoadingCalendar)
                }

                // Filter picker
                TodoFilterPicker(selection: $filter)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.md)
        }
    }

    // MARK: - Day Grouped List (Todoist-style)

    private var dayGroupedList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Overdue & No Date section at top
                if !overdueTodos.isEmpty || !noDateTodos.isEmpty {
                    OverdueSection(
                        overdueTodos: overdueTodos,
                        noDateTodos: noDateTodos,
                        onSelectTodo: { todo in
                            selectTodo(todo)
                        },
                        selectedTodoId: selectedTodoId
                    )

                    OttoDivider()
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                }

                // Day sections
                ForEach(dayGroups) { group in
                    DaySection(
                        date: group.date,
                        todos: group.todos,
                        events: group.events,
                        onAddTask: {
                            showingAddTodoForDate = group.date
                        },
                        onSelectTodo: { todo in
                            selectTodo(todo)
                        },
                        selectedTodoId: selectedTodoId
                    )

                    if group.id != dayGroups.last?.id {
                        OttoDivider()
                            .padding(.horizontal, Theme.Spacing.md)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    // MARK: - Completed List

    private var completedList: some View {
        Group {
            if completedTodos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(completedTodos) { todo in
                            TodoRowView(
                                todo: todo,
                                isSelected: selectedTodoId == todo.id,
                                onSelect: {
                                    selectTodo(todo)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: filter == .active ? "checkmark.circle" : "tray")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(filter == .active ? "All clear" : "No completed tasks")
                    .font(Theme.Typography.headline)
                Text(filter == .active ? "Looks like everything's organized." : "Complete some tasks to see them here.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func selectTodo(_ todo: Todo) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedTodoId == todo.id {
                selectedTodoId = nil
            } else {
                selectedTodoId = todo.id
            }
        }
    }
}

// MARK: - Quick Add Todo Sheet

struct QuickAddTodoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let prefilledDate: Date
    @State private var title: String = ""
    @State private var priority: Todo.Priority = .medium

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Header
            HStack {
                Text("Add Task")
                    .font(Theme.Typography.headline)

                Spacer()

                Text(formattedDate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Title input
            TextField("Task title", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.borderSubtle)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

            // Priority picker
            HStack {
                Text("Priority")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Spacer()

                Picker("", selection: $priority) {
                    ForEach(Todo.Priority.allCases, id: \.self) { p in
                        HStack {
                            Image(systemName: p.iconName)
                            Text(p.displayName)
                        }
                        .tag(p)
                    }
                }
                .pickerStyle(.menu)
            }

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                Button("Add Task") {
                    Task {
                        let todo = Todo(
                            title: title.isEmpty ? "New Task" : title,
                            dueDate: prefilledDate,
                            priority: priority
                        )
                        await appState.addTodo(todo)
                        dismiss()
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(title.isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 320)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM"
        return formatter.string(from: prefilledDate)
    }
}

// MARK: - Date Extension for Identifiable

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

#Preview {
    TodoListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
