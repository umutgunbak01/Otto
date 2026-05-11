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

enum HUDSettings {
    static let enabledKey = "hud_enabled"
    /// Default OFF — the menu-bar status item replaces this for most
    /// users. The HUD's Window scene reads this flag via
    /// `.defaultLaunchBehavior` to decide whether to auto-present
    /// at launch.
    static let defaultEnabled: Bool = false
}

enum MenuBarSettings {
    static let enabledKey = "menubar_enabled"
    /// Default ON — gives users the time + next-event surface they
    /// used to get from the floating HUD, in the standard macOS
    /// menu-bar location alongside other app icons.
    static let defaultEnabled: Bool = true
}
