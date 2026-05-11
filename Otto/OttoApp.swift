import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

@main
struct OttoApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .task {
                    configureWakeWord()
                    configureNotifications()
                    appState.meetingPrep.start()
                }
            #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    NSLog("[WakeWord] app resigned active — starting listener")
                    appState.wakeWord.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    NSLog("[WakeWord] app became active — stopping listener")
                    appState.wakeWord.stop()
                }
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)

        #if os(macOS)
        // Floating HUD — second scene, borderless, always-on-top, non-activating.
        // Opens automatically on launch; user can drag anywhere on screen and
        // macOS remembers the position across launches.
        Window("Otto HUD", id: "hud") {
            HUDView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 220, height: 92)
        .defaultPosition(.topTrailing)
        #endif
    }

    private func configureNotifications() {
        OttoNotificationDelegate.shared.appState = appState
        UNUserNotificationCenter.current().delegate = OttoNotificationDelegate.shared
    }

    private func configureWakeWord() {
        appState.wakeWord.onWake = { [appState] in
            Sounds.play(.wake)
            #if os(macOS)
            WindowActivator.bringToFront()
            #endif
            // First wake of the day → morning briefing; subsequent wakes →
            // plain greeting. Marker persists across app restarts via UserDefaults.
            if MorningBriefingService.shouldShowToday() {
                appState.pendingBriefing = true
                MorningBriefingService.markShownToday()
            } else {
                appState.pendingVoiceGreeting = "Welcome back, boss."
            }
            appState.showVoiceOverlay = true
            // The listener stops itself once the app becomes active; stop here
            // too so we don't double-transcribe if activation is delayed.
            appState.wakeWord.stop()
        }
    }

    private func handleOpenURL(_ url: URL) {
        // Handle otto://x-callback OAuth redirect
        guard url.scheme == "otto" else { return }

        if url.host == "x-callback" {
            Task {
                do {
                    _ = try await XAuthService.shared.handleCallback(url: url)
                    await MainActor.run {
                        appState.isXConnected = true
                    }
                    // Fetch user info and start sync
                    let me = try await XService.shared.fetchMe()
                    UserDefaults.standard.set(me.id, forKey: "x_user_id")
                    await appState.syncX()
                } catch {
                    await MainActor.run {
                        appState.xSyncError = error.localizedDescription
                    }
                }
            }
        }
    }
}
