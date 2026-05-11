import SwiftUI

struct TodoDetailView: View {
    @Environment(AppState.self) private var appState
    let todo: Todo
    var onClose: (() -> Void)? = nil
    var onNavigatePrevious: (() -> Void)? = nil
    var onNavigateNext: (() -> Void)? = nil

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var dueDate: Date? = nil
    @State private var priority: Todo.Priority = .medium
    @State private var showReminderPicker = false
    @State private var customReminderDate: Date = Date()
    @State private var reminderSet = false
    @State private var isEditingTitle = false
    @State private var isEditingDescription = false
    @State private var showDeleteConfirm = false

    // Sub-task state
    @State private var newSubTaskTitle: String = ""
    @State private var isAddingSubTask: Bool = false

    // Label state
    @State private var newTagName: String = ""
    @State private var isAddingTag: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            OttoDivider()

            // Two-column content
            HStack(alignment: .top, spacing: 0) {
                // Left: Main content area
                leftContent
                    .frame(maxWidth: .infinity)

                // Vertical divider
                OttoDivider()

                // Right: Properties sidebar
                rightSidebar
                    .frame(width: 240)
            }
        }
        .frame(width: 720, height: 520)
        .background(Theme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 24, x: 0, y: 8)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        .onAppear { loadTodo() }
        .onChange(of: todo.id) { loadTodo() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Project breadcrumb
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.accent)

                if let projectName = todo.todoistProjectName {
                    Text(projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                } else {
                    Text("To-Dos")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            Spacer()

            // Navigation arrows
            HStack(spacing: 2) {
                Button {
                    onNavigatePrevious?()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onNavigatePrevious == nil)
                .opacity(onNavigatePrevious != nil ? 1 : 0.3)

                Button {
                    onNavigateNext?()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onNavigateNext == nil)
                .opacity(onNavigateNext != nil ? 1 : 0.3)
            }

            // More menu
            Menu {
                // Convert type
                Menu("Convert to...") {
                    Button {
                        Task { await appState.convertTodo(todo, to: .note) }
                        onClose?()
                    } label: {
                        Label("Note", systemImage: "doc.text")
                    }
                    Button {
                        Task { await appState.convertTodo(todo, to: .idea) }
                        onClose?()
                    } label: {
                        Label("Idea", systemImage: "lightbulb")
                    }
                    Button {
                        Task { await appState.convertTodo(todo, to: .reminder) }
                        onClose?()
                    } label: {
                        Label("Reminder", systemImage: "bell")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    Task {
                        await appState.deleteTodo(todo)
                        onClose?()
                    }
                } label: {
                    Label("Delete Task", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif

            // Close button
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Left Content

    private var leftContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Checkbox + Title
                HStack(alignment: .top, spacing: 12) {
                    // Checkbox
                    Button {
                        Task { await appState.toggleTodo(todo) }
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(checkboxColor, lineWidth: 1.5)
                                .frame(width: 22, height: 22)

                            if todo.isCompleted {
                                Circle()
                                    .fill(checkboxColor)
                                    .frame(width: 22, height: 22)

                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.Colors.bg0)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    // Title
                    TextField("Task name", text: $title, axis: .vertical)
                        .font(.system(size: 20, weight: .semibold))
                        .textFieldStyle(.plain)
                        .strikethrough(todo.isCompleted, color: Theme.Colors.secondaryText)
                        .foregroundStyle(todo.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.text)
                        .lineLimit(1...5)
                        .onChange(of: title) { saveChanges() }
                }
                .padding(.bottom, 16)

                // Description
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Text("Description")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    TextEditor(text: $description)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                                .fill(Theme.Colors.borderSubtle.opacity(0.5))
                        )
                        .overlay(
                            Group {
                                if description.isEmpty {
                                    Text("Add a more detailed description...")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                        .onChange(of: description) { saveChanges() }
                }
                .padding(.bottom, 20)

                // Sub-tasks section
                subTasksSection
                    .padding(.bottom, 16)

                OttoDivider()
                    .padding(.bottom, 16)

                // Comment area
                commentSection

                // Completion info
                if todo.isCompleted, let completedAt = todo.completedAt {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.personal)

                        Text("Completed \(formatRelativeDate(completedAt))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .padding(.top, 12)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Sub-tasks Section

    private var subTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with count
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Sub-tasks")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if !todo.subTasks.isEmpty {
                    let completedCount = todo.subTasks.filter(\.isCompleted).count
                    Text("\(completedCount)/\(todo.subTasks.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(completedCount == todo.subTasks.count && !todo.subTasks.isEmpty ? Theme.Colors.personal : Theme.Colors.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.Colors.hoverTint)
                        .clipShape(Capsule())
                }
            }

            // Existing sub-tasks
            ForEach(todo.subTasks) { subTask in
                SubTaskRowView(
                    subTask: subTask,
                    onToggle: {
                        Task { await appState.toggleSubTask(todoId: todo.id, subTaskId: subTask.id) }
                    },
                    onDelete: {
                        Task { await appState.deleteSubTask(todoId: todo.id, subTaskId: subTask.id) }
                    }
                )
            }

            // Add sub-task
            if isAddingSubTask {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(Theme.Colors.tertiaryText.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 16, height: 16)

                    TextField("Sub-task title", text: $newSubTaskTitle)
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                        .onSubmit {
                            addSubTask()
                        }

                    Button {
                        isAddingSubTask = false
                        newSubTaskTitle = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAddingSubTask = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add sub-task")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func addSubTask() {
        let trimmed = newSubTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await appState.addSubTask(to: todo.id, title: trimmed)
        }
        newSubTaskTitle = ""
        // Keep isAddingSubTask true so user can add more
    }

    // MARK: - Comment Section

    private var commentSection: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar placeholder
            Circle()
                .fill(Theme.Colors.accent.opacity(0.15))
                .frame(width: 28, height: 28)
                .overlay(
                    Text("U")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                )

            // Comment input
            TextField("Comment", text: .constant(""))
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
        }
    }

    // MARK: - Right Sidebar

    private var rightSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Project
                propertyRow(
                    label: "Project",
                    icon: "tray",
                    iconColor: Theme.Colors.tertiaryText
                ) {
                    if let projectName = todo.todoistProjectName {
                        HStack(spacing: 4) {
                            Image(systemName: "number")
                                .font(.system(size: 10))
                            Text(projectName)
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(Theme.Colors.text)
                    } else {
                        Text("To-Dos")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.text)
                    }
                }

                OttoDivider()
                    .padding(.leading, 16)

                // Date
                datePropertyRow

                OttoDivider()
                    .padding(.leading, 16)

                // Priority
                priorityPropertyRow

                OttoDivider()
                    .padding(.leading, 16)

                // Labels
                labelsPropertyRow

                OttoDivider()
                    .padding(.leading, 16)

                // Reminders
                reminderPropertyRow

                OttoDivider()
                    .padding(.leading, 16)

                // Created date
                propertyRow(
                    label: "Created",
                    icon: "clock",
                    iconColor: Theme.Colors.tertiaryText
                ) {
                    Text(formatShortDate(todo.createdAt))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                // Todoist source badge
                if todo.todoistId != nil {
                    OttoDivider()
                        .padding(.leading, 16)

                    propertyRow(
                        label: "Source",
                        icon: "arrow.down.circle",
                        iconColor: Theme.Colors.red.opacity(0.7)
                    ) {
                        Text("Todoist")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Colors.red.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.red.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Labels Property Row

    private var labelsPropertyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labels")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            // Existing tags
            let tags = appState.tags(for: todo.domainTagIds)
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags) { tag in
                        TagChipView(
                            tag: tag,
                            isCompact: true,
                            isRemovable: true,
                            onRemove: {
                                Task { await appState.removeTagFromTodo(todo.id, tagId: tag.id) }
                            }
                        )
                    }
                }
            }

            // Add tag inline
            if isAddingTag {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        TextField("Tag name", text: $newTagName)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .onSubmit {
                                addTag()
                            }

                        Button {
                            isAddingTag = false
                            newTagName = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.hoverTint)
                    )

                    // Tag suggestions
                    let suggestions = tagSuggestions
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions) { tag in
                                Button {
                                    Task {
                                        await appState.addTagToTodo(todo.id, tagName: tag.name)
                                    }
                                    newTagName = ""
                                    isAddingTag = false
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "tag")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.Colors.tertiaryText)
                                        Text(tag.name)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Colors.text)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .fill(Theme.Colors.borderSubtle.opacity(0.5))
                        )
                    }
                }
            }

            // Add button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isAddingTag = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 16)

                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tagSuggestions: [DomainTag] {
        guard !newTagName.isEmpty else { return [] }
        let query = newTagName.lowercased()
        let currentTagIds = Set(todo.domainTagIds)
        return appState.domainTags
            .filter { $0.name.lowercased().contains(query) && !currentTagIds.contains($0.id) }
            .prefix(5)
            .map { $0 }
    }

    private func addTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await appState.addTagToTodo(todo.id, tagName: trimmed)
        }
        newTagName = ""
        isAddingTag = false
    }

    // MARK: - Property Row

    private func propertyRow<Content: View>(
        label: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .textCase(.none)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Date Property Row

    private var datePropertyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            TodoistDatePicker(date: $dueDate)
                .onChange(of: dueDate) { saveChanges() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Priority Property Row

    private var priorityPropertyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Priority")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Menu {
                ForEach([Todo.Priority.urgent, .high, .medium, .low], id: \.rawValue) { p in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            priority = p
                            saveChanges()
                        }
                    } label: {
                        HStack {
                            Image(systemName: iconFor(p))
                            Text(p.displayName)
                            if priority == p {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(priorityColor)
                        .frame(width: 16)

                    Text(priorityLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(priorityColor)
                }
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var priorityLabel: String {
        "P\(5 - priority.rawValue)"
    }

    // MARK: - Reminder Property Row

    private var reminderPropertyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reminders")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showReminderPicker.toggle()
                    if showReminderPicker {
                        customReminderDate = dueDate?.addingTimeInterval(-3600) ?? Date().addingTimeInterval(3600)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: reminderSet ? "bell.fill" : "bell")
                        .font(.system(size: 13))
                        .foregroundStyle(reminderSet ? Theme.Colors.priorityHigh : Theme.Colors.tertiaryText)
                        .frame(width: 16)

                    if reminderSet {
                        Text("Reminder set")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.personal)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }
            .buttonStyle(.plain)

            if showReminderPicker {
                reminderPickerContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var reminderPickerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let due = dueDate {
                reminderQuickOption(title: "1 day before", date: due.addingTimeInterval(-86400))
                reminderQuickOption(title: "1 hour before", date: due.addingTimeInterval(-3600))
                reminderQuickOption(title: "10 min before", date: due.addingTimeInterval(-600))
            }

            // Custom
            HStack(spacing: 6) {
                DatePicker("", selection: $customReminderDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .scaleEffect(0.85)
                    .frame(height: 28)

                Button {
                    Task {
                        await appState.createReminderForTodo(todo, at: customReminderDate)
                        withAnimation {
                            reminderSet = true
                            showReminderPicker = false
                        }
                    }
                } label: {
                    Text("Set")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.bg0)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.top, 4)
    }

    private func reminderQuickOption(title: String, date: Date) -> some View {
        Button {
            Task {
                await appState.createReminderForTodo(todo, at: date)
                withAnimation {
                    reminderSet = true
                    showReminderPicker = false
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.text)

                Spacer()

                Text(formatReminderDate(date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var checkboxColor: Color {
        if todo.isCompleted {
            return Theme.Colors.secondaryText
        }
        return priorityColor
    }

    private var priorityColor: Color {
        switch priority {
        case .low: return Theme.Colors.priorityLow
        case .medium: return Theme.Colors.priorityMedium
        case .high: return Theme.Colors.priorityHigh
        case .urgent: return Theme.Colors.priorityUrgent
        }
    }

    private func iconFor(_ priority: Todo.Priority) -> String {
        switch priority {
        case .low: return "flag"
        case .medium: return "flag.fill"
        case .high: return "flag.fill"
        case .urgent: return "exclamationmark.triangle.fill"
        }
    }

    private func loadTodo() {
        title = todo.title
        description = todo.description
        priority = todo.priority
        dueDate = todo.dueDate
        isAddingSubTask = false
        newSubTaskTitle = ""
        isAddingTag = false
        newTagName = ""
    }

    private func saveChanges() {
        var updated = todo
        updated.title = title
        updated.description = description
        updated.priority = priority
        updated.dueDate = dueDate

        Task { await appState.updateTodo(updated) }
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private func formatReminderDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - SubTask Row View

private struct SubTaskRowView: View {
    let subTask: Todo.SubTask
    var onToggle: () -> Void
    var onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Mini checkbox
            Button {
                onToggle()
            } label: {
                ZStack {
                    Circle()
                        .stroke(subTask.isCompleted ? Theme.Colors.secondaryText : Theme.Colors.tertiaryText, lineWidth: 1.5)
                        .frame(width: 16, height: 16)

                    if subTask.isCompleted {
                        Circle()
                            .fill(Theme.Colors.secondaryText)
                            .frame(width: 16, height: 16)

                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Colors.bg0)
                    }
                }
            }
            .buttonStyle(.plain)

            // Title
            Text(subTask.title)
                .font(.system(size: 13))
                .strikethrough(subTask.isCompleted, color: Theme.Colors.tertiaryText)
                .foregroundStyle(subTask.isCompleted ? Theme.Colors.tertiaryText : Theme.Colors.text)
                .lineLimit(1)

            Spacer()

            // Delete on hover
            if isHovered {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isHovered ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.opacity(0.3)
            .ignoresSafeArea()

        TodoDetailView(
            todo: Todo(
                title: "Review project proposal",
                description: "Go through the Q2 proposal document",
                dueDate: Calendar.current.date(from: DateComponents(year: 2025, month: 2, day: 4)),
                priority: .high,
                subTasks: [
                    .init(title: "Read executive summary", isCompleted: true),
                    .init(title: "Check budget section"),
                    .init(title: "Review timeline")
                ]
            ),
            onClose: { print("Close") },
            onNavigatePrevious: { print("Prev") },
            onNavigateNext: { print("Next") }
        )
    }
    .environment(AppState())
    .frame(width: 800, height: 600)
}
