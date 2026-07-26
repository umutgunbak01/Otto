#if os(macOS)
import AppKit

/// Hides Otto's on-screen surfaces from screen capture / screen sharing while a
/// meeting is being transcribed, so the people you share your screen with don't
/// see that Otto is listening.
///
/// The only first-party lever macOS gives us is `NSWindow.sharingType = .none`,
/// which asks the window server to omit the window from screen captures. It is
/// honored by browser-based screen shares (Google Meet, Zoom/Teams shared from
/// a tab — the common case) and by the legacy window-capture path. On macOS
/// 15.4+ a *native* full-display ScreenCaptureKit recorder (the Zoom app in some
/// modes, QuickTime, OBS) may still composite the window in — Apple confirms
/// there's no public API that guarantees exclusion. So this is best-effort
/// stealth, strongest for the browser-share case; we set the flag because it's
/// free and covers the common path, without over-promising on the rest.
///
/// Two kinds of surface are managed:
///   - the floating meeting banner (`MeetingBannerController`'s panel) — hidden
///     from capture whenever the feature is on, since it literally reads
///     "Transcribing" (and the "Meeting detected" prompt is just as telling);
///   - the app's content windows — hidden only while a recording is in flight,
///     then restored to the default `.readOnly` so the user can still
///     screen-share Otto normally outside of a meeting.
///
/// We deliberately don't try to *detect* an active screen share: `.none` is
/// invisible to the user's own display and only affects captures, so hiding for
/// the whole recording covers any share that starts mid-meeting with no
/// detection race or flicker.
///
/// Imperative singleton in the mold of `MenuBarController` /
/// `MeetingBannerController`; the transcription coordinator drives it.
@MainActor
final class ScreenCapturePrivacyController {
    static let shared = ScreenCapturePrivacyController()

    /// User setting (Settings → Interface). Cached; refreshed via `syncSetting`.
    private var enabled: Bool
    /// True between a recording's start and stop.
    private var recording = false
    /// The banner panel, protected whenever the feature is on. Weak: owned by
    /// `MeetingBannerController`.
    private weak var bannerPanel: NSPanel?
    /// Content windows we've switched to `.none`, remembered so we can restore
    /// exactly those (and never reveal a window that was already `.none`).
    private var hiddenWindows: [NSWindow] = []
    /// Catches windows created *during* a recording (sheets, new windows).
    private var newWindowObserver: NSObjectProtocol?

    private init() {
        enabled = UserDefaults.standard.object(forKey: ScreenCapturePrivacySettings.enabledKey) as? Bool
            ?? ScreenCapturePrivacySettings.defaultEnabled
    }

    // MARK: - Inputs

    /// Called once by `MeetingBannerController` when it lazily builds its panel.
    /// The panel's sharing type persists across `orderOut`/`orderFront`, so a
    /// single application here holds for the panel's lifetime; `syncSetting`
    /// updates it if the user flips the setting.
    func protectBannerPanel(_ panel: NSPanel) {
        bannerPanel = panel
        panel.sharingType = enabled ? .none : .readOnly
    }

    /// Called by `MeetingTranscriptionCoordinator` around a recording.
    func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        applyContentWindows()
    }

    /// Called by `OttoApp` when the Settings toggle changes.
    func syncSetting() {
        let now = UserDefaults.standard.object(forKey: ScreenCapturePrivacySettings.enabledKey) as? Bool
            ?? ScreenCapturePrivacySettings.defaultEnabled
        guard now != enabled else { return }
        enabled = now
        bannerPanel?.sharingType = enabled ? .none : .readOnly
        applyContentWindows()
    }

    // MARK: - Content-window hiding

    private var shouldHideContent: Bool { enabled && recording }

    private func applyContentWindows() {
        if shouldHideContent {
            hideAllContentWindows()
            startObservingNewWindows()
        } else {
            stopObservingNewWindows()
            restoreHiddenWindows()
        }
    }

    private func hideAllContentWindows() {
        for window in NSApp.windows where isManageable(window) && window.sharingType != .none {
            window.sharingType = .none
            hiddenWindows.append(window)
        }
    }

    private func restoreHiddenWindows() {
        for window in hiddenWindows { window.sharingType = .readOnly }
        hiddenWindows.removeAll()
    }

    /// Windows we may switch to `.none`: any real app window, but never the
    /// banner panel — it manages its own sharing type and must stay hidden
    /// across recordings, not get restored to `.readOnly` when one ends.
    private func isManageable(_ window: NSWindow) -> Bool {
        window !== bannerPanel
    }

    private func startObservingNewWindows() {
        guard newWindowObserver == nil else { return }
        // `.main` queue → delivery is on the main thread, so it's safe to reach
        // main-actor state synchronously via `assumeIsolated` (which also avoids
        // hopping a non-Sendable NSWindow across an async boundary).
        newWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.shouldHideContent,
                      let window = note.object as? NSWindow,
                      self.isManageable(window), window.sharingType != .none else { return }
                window.sharingType = .none
                self.hiddenWindows.append(window)
            }
        }
    }

    private func stopObservingNewWindows() {
        if let newWindowObserver {
            NotificationCenter.default.removeObserver(newWindowObserver)
            self.newWindowObserver = nil
        }
    }
}
#endif
