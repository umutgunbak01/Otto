#if os(macOS)
import AppKit
import SwiftUI

/// Owns Otto's macOS menu-bar (status-bar) item. Replaces the older
/// floating HUD: a compact text label that lives alongside the other
/// app icons in the system menu bar, refreshing every 30 seconds with
/// the current time and a short countdown to the user's next calendar
/// event.
///
/// Click → brings Otto's main window forward via `WindowActivator`.
/// (No right-click menu in v1; ⌘Q from Otto's main window quits.)
///
/// Lifecycle is driven from `OttoApp`: `install(appState:)` once on
/// launch when the user has the integration enabled, `uninstall()`
/// to remove the item when the user toggles it off in Settings.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private weak var appState: AppState?

    var isInstalled: Bool { statusItem != nil }

    // MARK: - Install / Uninstall

    func install(appState: AppState) {
        guard statusItem == nil else { return }
        self.appState = appState

        // `variableLength` lets the label grow with the countdown text.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        statusItem = item

        startTimer()
        refresh()
    }

    func uninstall() {
        timer?.invalidate()
        timer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Refresh

    /// Recompute the title shown next to the system clock. Public so the
    /// app can poke it after a Calendar sync to reduce staleness.
    func refresh() {
        guard let state = appState, let button = statusItem?.button else { return }
        button.title = Self.makeTitle(now: Date(), events: state.calendarEvents)
    }

    private func startTimer() {
        // 30 s is plenty of resolution: gives the user a live countdown
        // without burning much CPU. The label only re-renders if the
        // computed string actually changes.
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Title rendering

    /// Returns a compact label like `10:35  ·  12m → Standup` or just
    /// `10:35` when nothing is upcoming. Truncates the meeting title
    /// at 24 chars to keep the menu bar quiet.
    static func makeTitle(now: Date, events: [CalendarEvent]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let time = timeFmt.string(from: now)

        guard let next = events
                .filter({ $0.startTime > now })
                .min(by: { $0.startTime < $1.startTime })
        else { return time }

        let delta = next.startTime.timeIntervalSince(now)
        let countdown: String = {
            if delta < 60 { return "now" }
            let minutes = Int(delta / 60)
            if minutes < 60 { return "\(minutes)m" }
            let hours = minutes / 60
            let rem = minutes % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h\(rem)m"
        }()

        // Only annotate with the title when the event is within an hour;
        // beyond that the user mostly wants the clock with a hint that
        // something's coming up.
        if delta > 60 * 60 { return time + "  ·  next " + countdown }
        let title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return time + "  ·  " + countdown }
        let trimmed = title.count > 24 ? String(title.prefix(24)) + "…" : title
        return time + "  ·  " + countdown + " → " + trimmed
    }

    // MARK: - Click

    @objc private func handleClick() {
        WindowActivator.bringToFront()
    }
}
#endif
