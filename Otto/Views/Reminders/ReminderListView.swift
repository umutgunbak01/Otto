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
                OttoDivider()

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
            // Header
            header

            OttoDivider()

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
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("⌬ REMINDERS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(activeReminders.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
        }
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
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "bell")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text("No reminders")
                    .font(Theme.Typography.title)
                Text("Try: \"Remind me to call mom at 5pm\"")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ReminderListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
