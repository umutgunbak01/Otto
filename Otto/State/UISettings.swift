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

enum MeetingDetectionSettings {
    static let enabledKey = "meeting_detection_enabled"
    /// Default ON — when another app grabs the microphone (Zoom, Meet in a
    /// browser, …), Otto offers a floating "Start transcribing" prompt.
    static let defaultEnabled: Bool = true
}

enum MenuBarSettings {
    static let enabledKey = "menubar_enabled"
    /// Default ON — gives users the time + next-event surface they
    /// used to get from the floating HUD, in the standard macOS
    /// menu-bar location alongside other app icons.
    static let defaultEnabled: Bool = true
}

enum ScreenCapturePrivacySettings {
    static let enabledKey = "screen_capture_privacy_enabled"
    /// Default ON — while a meeting is being transcribed, Otto's banner and
    /// windows are excluded from screen capture (`NSWindow.sharingType = .none`)
    /// so people you screen-share with don't see that you're transcribing.
    /// Best-effort: honored by browser-based shares (Meet, Zoom/Teams in a tab)
    /// and legacy window capture, but a native full-display ScreenCaptureKit
    /// recorder on macOS 15.4+ may still composite the window in. Users who want
    /// to screen-share Otto during a call can turn it off.
    static let defaultEnabled: Bool = true
}

// MARK: - Connections column layout
//
// Per-device preference for which CRM columns are visible, their order, and
// their widths. Kept in UserDefaults (not in otto_data.json) so it stays
// local to this Mac — moving the data file doesn't drag your column setup.
// The `_v1` key suffix gives us room to migrate if `ColumnLayout`'s schema
// ever changes.

enum ConnectionColumnLayoutStore {
    // v2: expanded default visible columns to cover every "More Info" field
    // (phone, email, birthday, education). The version bump forces existing
    // saved layouts to fall back to the new default — users can still hide
    // anything they don't want via the Columns menu.
    static let key = "connections_column_layout_v2"

    static func load() -> ColumnLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ColumnLayout.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    static func save(_ layout: ColumnLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
