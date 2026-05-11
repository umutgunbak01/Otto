import Foundation

/// User-toggleable UI preferences. Kept as plain enums (not @Observable)
/// because each is read via `@AppStorage` from the SwiftUI views that
/// care; the enums are just a place to keep the key strings and default
/// values together so a typo in the key on one side doesn't silently
/// reset a setting.

enum WakeWordSettings {
    static let enabledKey = "wake_word_enabled"
    /// Default ON — preserves the pre-existing behaviour where Otto
    /// listened for the wake phrase whenever it was in the background.
    static let defaultEnabled: Bool = true
}

// The legacy floating-HUD widget was retired in favour of the menu-bar
// status item below. HUDView.swift is kept around in case anyone wants
// to bring it back behind a Settings toggle later, but there's no
// active flag controlling it today and no Window scene wired for it
// in `OttoApp` — macOS has nothing to restore.

enum MenuBarSettings {
    static let enabledKey = "menubar_enabled"
    /// Default ON — gives users the time + next-event surface they
    /// used to get from the floating HUD, in the standard macOS
    /// menu-bar location alongside other app icons.
    static let defaultEnabled: Bool = true
}
