import Foundation
import UserNotifications

/// Handles taps on Otto's system notifications. Today it routes meeting-prep
/// notifications to the backing Note; future notification types can dispatch
/// off additional `userInfo` keys.
///
/// Set once from `OttoApp.task`:
/// ```
/// OttoNotificationDelegate.shared.appState = appState
/// UNUserNotificationCenter.current().delegate = OttoNotificationDelegate.shared
/// ```
final class OttoNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = OttoNotificationDelegate()

    weak var appState: AppState?

    private override init() { super.init() }

    /// Present the banner even when the app is frontmost (default is to
    /// suppress system banners while active). Useful for meeting-prep pings.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Route taps. `noteId` → open that Note; other userInfo keys can be
    /// added as new notification kinds appear.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let raw = info["noteId"] as? String, let id = UUID(uuidString: raw) {
            Task { @MainActor in
                self.openNote(id: id)
                completionHandler()
            }
            return
        }
        completionHandler()
    }

    @MainActor
    private func openNote(id: UUID) {
        guard let state = appState else { return }
        guard let note = state.notes.first(where: { $0.id == id }) else { return }
        state.selectedTab = .note
        state.selectedNote = note
        #if os(macOS)
        WindowActivator.bringToFront()
        #endif
    }
}
