import SwiftUI

/// The Automations tab: recurring agent tasks (top) and the saved-prompt
/// library (bottom). Tasks run through `TaskSchedulerService` as background
/// chat sessions; run-history rows deep-link into those sessions.
struct AutomationsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AutomationSettings.pausedKey) private var paused = AutomationSettings.defaultPaused

    @State private var sheet: SheetTarget?
    @State private var expandedTaskIds: Set<UUID> = []
    @State private var hoveredTaskId: UUID?
    @State private var hoveredPromptId: UUID?

    private enum SheetTarget: Identifiable {
        case newTask(name: String?, prompt: String?)
        case editTask(ScheduledTask)
        case newPrompt
        case editPrompt(SavedPrompt)

        var id: String {
            switch self {
            case .newTask:             return "newTask"
            case .editTask(let t):     return "editTask-\(t.id.uuidString)"
            case .newPrompt:           return "newPrompt"
            case .editPrompt(let p):   return "editPrompt-\(p.id.uuidString)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if appState.scheduledTasks.isEmpty && appState.savedPrompts.isEmpty {
                fullEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tasksSection
                        promptsSection
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xxl)
                    .frame(maxWidth: 828)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $sheet) { target in
            switch target {
            case .newTask(let name, let prompt):
                ScheduledTaskEditorSheet(existing: nil, draftName: name, draftPrompt: prompt)
            case .editTask(let task):
                ScheduledTaskEditorSheet(existing: task)
            case .newPrompt:
                SavedPromptEditorSheet(existing: nil)
            case .editPrompt(let prompt):
                SavedPromptEditorSheet(existing: prompt)
            }
        }
    }

    // MARK: - Viewbar

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Automations")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: countChipText)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Text(paused ? "PAUSED" : "ACTIVE")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(paused ? Theme.Colors.amber : Theme.Colors.tertiaryText)
                Toggle("", isOn: Binding(
                    get: { !paused },
                    set: { on in
                        paused = !on
                        if on { appState.taskScheduler.tickSoon() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(OttoToggleStyle())
            }
            .help(paused
                  ? "Scheduler is paused — due tasks wait and catch up when resumed"
                  : "Pause all recurring tasks")

            OttoBarButton(label: "New prompt") {
                sheet = .newPrompt
            }

            OttoNewButton(label: "New task") {
                sheet = .newTask(name: nil, prompt: nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var countChipText: String {
        let tasks = appState.scheduledTasks.count
        let prompts = appState.savedPrompts.count
        let taskPart = tasks == 1 ? "1 task" : "\(tasks) tasks"
        let promptPart = prompts == 1 ? "1 prompt" : "\(prompts) prompts"
        return "\(taskPart) · \(promptPart)"
    }

    // MARK: - Full empty state

    private var fullEmptyState: some View {
        OttoEmptyState(
            systemImage: "cpu",
            title: "Nothing scheduled",
            message: "Give Otto a job on a timer — it runs in the background, files the results, and pings you only when something needs you.",
            tip: "Runs via your agent backend · results land in chat history"
        ) {
            OttoFlowLayout(spacing: 8, alignment: .center) {
                OttoSuggestionChip(systemImage: "sun.max", label: "Refresh my briefing every morning") {
                    sheet = .newTask(name: nil, prompt: nil)
                }
                OttoSuggestionChip(systemImage: "doc.text", label: "Draft a weekly review every Friday") {
                    sheet = .newTask(name: nil, prompt: nil)
                }
            }
        }
    }

    // MARK: - Recurring tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttoGroupLabel(text: "Scheduled tasks", count: appState.scheduledTasks.count)

            if appState.scheduledTasks.isEmpty {
                emptyCard(
                    icon: "calendar.badge.clock",
                    title: "No recurring tasks yet",
                    body: "Schedule a prompt to run on its own — every morning, weekdays, or monthly. If your Mac was asleep at the scheduled time, the task catches up as soon as Otto is back."
                )
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(appState.scheduledTasks) { task in
                        taskCard(task)
                    }
                }
            }
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        let isRunning = appState.taskScheduler.isRunning(task.id)
        let isExpanded = expandedTaskIds.contains(task.id)
        let isHovered = hoveredTaskId == task.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                OttoSquare(systemImage: "cpu", color: Theme.Colors.cyan, dim: !task.isEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(task.schedule.displaySummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        if task.autoApproveTools {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.accentText)
                                .help("Auto-approves tool requests during runs")
                        }
                        statusChip(for: task, isRunning: isRunning)
                    }
                }

                Spacer()

                if !task.runs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded { expandedTaskIds.remove(task.id) }
                            else { expandedTaskIds.insert(task.id) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(task.runs.count)")
                                .font(.system(size: 10, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Run history")
                }

                Button {
                    appState.taskScheduler.runNow(task)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isRunning ? Theme.Colors.tertiaryText : Theme.Colors.cyan)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .help("Run now (doesn't affect the schedule)")

                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { on in
                        var updated = task
                        updated.isEnabled = on
                        Task { await appState.saveScheduledTaskEdits(updated) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(OttoToggleStyle())
            }
            .padding(Theme.Spacing.md)
            .contentShape(Rectangle())
            .onTapGesture { sheet = .editTask(task) }

            if isExpanded && !task.runs.isEmpty {
                OttoDivider()
                VStack(spacing: 0) {
                    ForEach(task.runs) { run in
                        runRow(run)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        .opacity(task.isEnabled ? 1 : 0.65)
        .onHover { hovering in
            if hovering { hoveredTaskId = task.id }
            else if hoveredTaskId == task.id { hoveredTaskId = nil }
        }
        .contextMenu {
            Button("Run Now") { appState.taskScheduler.runNow(task) }
                .disabled(isRunning)
            Button("Edit…") { sheet = .editTask(task) }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await appState.deleteScheduledTask(task) }
            }
        }
    }

    @ViewBuilder
    private func statusChip(for task: ScheduledTask, isRunning: Bool) -> some View {
        if isRunning {
            chip(text: "Running…", color: Theme.Colors.green, showsSpinner: true)
        } else if !task.isEnabled {
            chip(text: "Off", color: Theme.Colors.tertiaryText)
        } else if appState.taskScheduler.isWaitingForBackend(task) {
            chip(text: "Waiting for agent backend", color: Theme.Colors.amber)
        } else if let due = task.nextDueAt {
            if due <= Date() {
                chip(text: "Due — running at first chance", color: Theme.Colors.amber)
            } else {
                chip(text: "Next \(Self.nextRunText(due))", color: Theme.Colors.tertiaryText)
            }
        }
    }

    private func chip(text: String, color: Color, showsSpinner: Bool = false) -> some View {
        HStack(spacing: 4) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1))
    }

    private func runRow(_ run: TaskRunRecord) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(runColor(run.status))
                .frame(width: 6, height: 6)

            Text(Self.runDateFormatter.string(from: run.startedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Colors.textDim)

            Text(run.status.displayName + (run.wasManual ? " · manual" : ""))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(runColor(run.status))

            if let finished = run.finishedAt, run.status != .interrupted {
                Text(Self.durationText(from: run.startedAt, to: finished))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            if let error = run.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                    .help(error)
            }

            Spacer()

            if let sessionId = run.chatSessionId, appState.chatSession(sessionId) != nil {
                Button("Open chat") {
                    appState.pendingOpenChatSessionId = sessionId
                }
                .font(.system(size: 10.5, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.accentText)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 5)
    }

    private func runColor(_ status: TaskRunRecord.Status) -> Color {
        switch status {
        case .running:     return Theme.Colors.cyan
        case .succeeded:   return Theme.Colors.green
        case .failed:      return Theme.Colors.red
        case .interrupted: return Theme.Colors.amber
        }
    }

    // MARK: - Saved prompts

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            OttoGroupLabel(text: "Saved prompts", count: appState.savedPrompts.count)

            if appState.savedPrompts.isEmpty {
                emptyCard(
                    icon: "bookmark",
                    title: "No saved prompts yet",
                    body: "Save prompts you reuse — insert them from the bookmark button in the chat composer, or turn one into a recurring task."
                )
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(appState.savedPrompts) { prompt in
                        promptCard(prompt)
                    }
                }
            }
        }
    }

    private func promptCard(_ prompt: SavedPrompt) -> some View {
        let isHovered = hoveredPromptId == prompt.id

        return HStack(spacing: Theme.Spacing.md) {
            OttoSquare(systemImage: "bookmark", color: Theme.Colors.amber)

            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text(prompt.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 2) {
                OttoGlyphButton(systemImage: "arrow.up.message", help: "Use in chat", size: 26) {
                    Task { await appState.markSavedPromptUsed(id: prompt.id) }
                    appState.pendingComposerInsert = prompt.prompt
                }
                OttoGlyphButton(systemImage: "calendar.badge.plus", help: "Schedule as recurring task", size: 26) {
                    sheet = .newTask(name: prompt.name, prompt: prompt.prompt)
                }
                OttoGlyphButton(systemImage: "pencil", help: "Edit", size: 26) {
                    sheet = .editPrompt(prompt)
                }
                OttoGlyphButton(systemImage: "trash", help: "Delete", size: 26) {
                    Task { await appState.deleteSavedPrompt(prompt) }
                }
            }
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { sheet = .editPrompt(prompt) }
        .onHover { hovering in
            if hovering { hoveredPromptId = prompt.id }
            else if hoveredPromptId == prompt.id { hoveredPromptId = nil }
        }
        .contextMenu {
            Button("Use in Chat") {
                Task { await appState.markSavedPromptUsed(id: prompt.id) }
                appState.pendingComposerInsert = prompt.prompt
            }
            Button("Schedule as Task…") {
                sheet = .newTask(name: prompt.name, prompt: prompt.prompt)
            }
            Button("Edit…") { sheet = .editPrompt(prompt) }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await appState.deleteSavedPrompt(prompt) }
            }
        }
    }

    // MARK: - Shared bits

    private func emptyCard(icon: String, title: String, body bodyText: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.bottom, 3)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.text)
            Text(bodyText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(
                    Color.white.opacity(0.17),
                    style: StrokeStyle(lineWidth: 1, dash: [3.5, 3.5])
                )
        )
    }

    // MARK: - Formatting

    /// "Today 09:00", "Tomorrow 09:00", else "Wed · Jul 30 · 09:00".
    static func nextRunText(_ date: Date, calendar: Calendar = .current) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return "\(dayFormatter.string(from: date)) \(time)"
    }

    static func durationText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private static let runDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}
