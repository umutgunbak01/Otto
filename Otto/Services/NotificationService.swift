import Foundation
import UserNotifications

actor NotificationService {
    static let shared = NotificationService()

    /// Set once from `AppState.init` so the service can honor `quietUntil`.
    /// Weak so AppState's lifetime drives; actor never retains the owner.
    private weak var appState: AppState?

    private init() {}

    func configure(appState: AppState) {
        self.appState = appState
    }

    /// True if the user has asked for quiet and that window covers `date`.
    /// Checked on MainActor because AppState is not Sendable outside of it.
    private func quietAt(_ date: Date) async -> Bool {
        guard let state = appState else { return false }
        let until = await MainActor.run { state.quietUntil }
        guard let until = until else { return false }
        return date < until
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }

    /// Generic notification tied to a Note — used for meeting prep. Body is
    /// shown in the system notification banner; tapping it routes through
    /// `OttoNotificationDelegate` to open the specific Note.
    @discardableResult
    func scheduleNote(noteId: UUID, title: String, body: String, fireAt: Date) async throws -> String {
        if await quietAt(fireAt) { return "" }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["noteId": noteId.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let notificationId = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(request)
        return notificationId
    }

    func scheduleReminder(_ reminder: Reminder) async throws -> String {
        // Quiet-mode gate: if the reminder would fire during a user-requested
        // silence window, skip scheduling entirely. Returns an empty id; the
        // caller can treat that as "not scheduled".
        if await quietAt(reminder.reminderDate) {
            return ""
        }
        let content = UNMutableNotificationContent()
        content.title = "Otto Reminder"
        content.body = reminder.title
        content.sound = .default
        content.userInfo = ["reminderId": reminder.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.reminderDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let notificationId = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: trigger
        )

        try await UNUserNotificationCenter.current().add(request)
        return notificationId
    }

    func cancelReminder(notificationId: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationId])
    }

    func cancelAllReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func getPendingNotifications() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }
}
