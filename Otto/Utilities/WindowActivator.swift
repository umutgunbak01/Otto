import Foundation

#if os(macOS)
import AppKit

/// Brings the Otto window to the front on macOS. Used by the wake-word path to
/// surface the app when the user says the trigger phrase from another space.
enum WindowActivator {
    /// Bring the Otto window to the absolute front, even if the app is hidden,
    /// minimized, or another app is frontmost. macOS 14+ tightened
    /// `activate(ignoringOtherApps:)` so we pair it with `orderFrontRegardless()`
    /// and explicit un-hide / de-miniaturize to cover every state.
    static func bringToFront() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Also ask the running-application API — some OS versions honor this
        // when NSApp.activate alone is ignored.
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }

        let window = NSApp.windows.first(where: { $0.canBecomeKey }) ?? NSApp.windows.first
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif
