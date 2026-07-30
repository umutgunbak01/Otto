import SwiftUI

struct ReminderListView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedReminderId: UUID?

    /// Active reminders (not completed), sorted with past due first, then by date
    var activeReminders: [Reminder] {
        appState.reminders
            .filter { !$0.isCompleted }
            .sorted { r1, r2 in
                // Past due items come first
                if r1.isPastDue && !r2.isPastDue { return true }
                if !r1.isPastDue && r2.isPastDue { return false }
                // Then sort by date (earliest first)
                return r1.reminderDate < r2.reminderDate
            }
    }

    private var showDetailPanel: Bool {
        selectedReminderId != nil && appState.reminders.contains(where: { $0.id == selectedReminderId })
    }

    var body: some View {
        HStack(spacing: 0) {
            // List Panel - expands when detail is hidden
            listPanel
                .frame(minWidth: 320, maxWidth: showDetailPanel ? 400 : .infinity)

            if showDetailPanel {
                OttoVerticalDivider()

                // Detail Panel - collapsible
                detailPanel
                    .frame(minWidth: 350, maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDetailPanel)
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.reminders.contains(where: { $0.id == itemId }) {
                selectedReminderId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.reminders.contains(where: { $0.id == itemId }) {
                selectedReminderId = itemId
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let reminderId = selectedReminderId,
               let reminder = appState.reminders.first(where: { $0.id == reminderId }) {
                ReminderDetailView(
                    reminder: reminder,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedReminderId = nil
                        }
                    }
                )
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header — no hairline underneath; content scrolls directly below.
            header

            // Content
            if activeReminders.isEmpty {
                emptyState
            } else {
                reminderList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Reminders")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(activeReminders.count)")

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Reminder List

    private var reminderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(activeReminders) { reminder in
                    ReminderRowView(reminder: reminder, isSelected: selectedReminderId == reminder.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if selectedReminderId == reminder.id {
                                    selectedReminderId = nil // Toggle off if already selected
                                } else {
                                    selectedReminderId = reminder.id
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "bell",
            title: "All quiet",
            message: "Reminders you or Otto create show up here and fire as macOS notifications.",
            tip: "Try: \"Remind me to call mom at 19:00\""
        )
    }
}

#Preview {
    ReminderListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
