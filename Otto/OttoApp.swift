import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
import Sparkle
#endif

@main
struct OttoApp: App {
    @State private var appState = AppState()

    /// User preferences. Wake-word listening defaults ON (legacy
    /// behaviour); the menu-bar status item also defaults ON and
    /// replaces the floating HUD that used to live here.
    @AppStorage(WakeWordSettings.enabledKey) private var wakeWordEnabled: Bool = WakeWordSettings.defaultEnabled
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled: Bool = MenuBarSettings.defaultEnabled

    #if os(macOS)
    /// Sparkle auto-update controller. Polls the appcast at SUFeedURL
    /// (see Info.plist) on launch and on the user's manual trigger.
    /// `startingUpdater: true` lets Sparkle schedule background checks
    /// per SUEnableAutomaticChecks; we still expose a manual entry
    /// point via the app menu and the menu-bar status item.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task {
                    configureWakeWord()
                    configureNotifications()
                    appState.meetingPrep.start()
                    #if os(macOS)
                    syncMenuBar()
                    #endif
                }
            #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    guard wakeWordEnabled else { return }
                    NSLog("[WakeWord] app resigned active — starting listener")
                    appState.wakeWord.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    NSLog("[WakeWord] app became active — stopping listener")
                    appState.wakeWord.stop()
                }
                // App quitting → tear down the long-lived Hermes SSH+ACP
                // session if one is open. Other backends (Claude/Codex) are
                // per-turn subprocesses with nothing to clean up on quit.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task { await HermesAgentService.shared.disconnect() }
                }
                .onChange(of: wakeWordEnabled) { _, enabled in
                    // Toggled OFF while backgrounded → cut the mic now,
                    // don't wait for the next foreground bounce.
                    if !enabled { appState.wakeWord.stop() }
                }
                .onChange(of: menuBarEnabled) { _, _ in syncMenuBar() }
            #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)
        #if os(macOS)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
        #endif
        // No HUD Window scene anymore — the menu-bar status item
        // (MenuBarController) covers the same surface (time + next
        // event) without floating on top of every other window.
        // The HUDView.swift file is retained for now in case we want
        // to bring the widget back behind a Settings toggle later,
        // but it's not wired into a Scene so macOS has nothing to
        // restore from prior sessions.
    }

    #if os(macOS)
    private func syncMenuBar() {
        if menuBarEnabled {
            MenuBarController.shared.install(appState: appState, updater: updaterController)
        } else {
            MenuBarController.shared.uninstall()
        }
    }
    #endif

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

}
