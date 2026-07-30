import Foundation

#if os(macOS)
import AppKit
import Carbon.HIToolbox

// MARK: - Shortcut model

/// A recorded global shortcut: hardware key + modifier set, plus the display
/// string captured at record time (so "⌥Space" survives keyboard-layout
/// changes without us re-deriving the glyph). JSON-encoded into UserDefaults
/// under `QuickCaptureSettings.shortcutKey`.
struct QuickCaptureShortcut: Codable, Equatable {
    /// Hardware key code (`NSEvent.keyCode`, same space as Carbon's `kVK_*`).
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, masked to device-independent flags.
    var modifierFlags: UInt
    /// Human-readable form, e.g. "⌥Space" — built once at record time.
    var display: String

    /// ⌥Space — the classic quick-capture chord; doesn't collide with
    /// Spotlight's ⌘Space and is remappable in Settings → Interface.
    static let `default` = QuickCaptureShortcut(
        keyCode: UInt32(kVK_Space),
        modifierFlags: NSEvent.ModifierFlags.option.rawValue,
        display: "⌥Space"
    )

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    /// Build from a keyDown event, rejecting chords a global hotkey shouldn't
    /// claim: bare keys / shift-only chords would fire while the user types
    /// in other apps. Function keys are exempt (F-keys are chords by nature).
    init?(event: NSEvent) {
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        let isFunctionKey = Self.functionKeyNames[event.keyCode] != nil
        guard isFunctionKey || !mods.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        self.keyCode = UInt32(event.keyCode)
        self.modifierFlags = mods.rawValue
        self.display = Self.modifierGlyphs(mods) + Self.keyName(for: event)
    }

    init(keyCode: UInt32, modifierFlags: UInt, display: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.display = display
    }

    /// Carbon's modifier bit set, for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var out: UInt32 = 0
        if modifiers.contains(.command) { out |= UInt32(cmdKey) }
        if modifiers.contains(.option)  { out |= UInt32(optionKey) }
        if modifiers.contains(.control) { out |= UInt32(controlKey) }
        if modifiers.contains(.shift)   { out |= UInt32(shiftKey) }
        return out
    }

    // MARK: Display helpers

    private static func modifierGlyphs(_ mods: NSEvent.ModifierFlags) -> String {
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option)  { out += "⌥" }
        if mods.contains(.shift)   { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out
    }

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeyNames[event.keyCode] ?? functionKeyNames[event.keyCode] {
            return special
        }
        // `charactersIgnoringModifiers` strips ⌥/⌃ layers (keeps Shift), so
        // ⌥A records as "A" rather than "å".
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
    ]

    private static let functionKeyNames: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]
}

// MARK: - Global hotkey (Carbon)

/// Thin wrapper over Carbon's `RegisterEventHotKey` — the one macOS API that
/// delivers a system-wide shortcut without Accessibility / Input Monitoring
/// permission. One instance, one hotkey (quick capture is the only consumer);
/// the Carbon event handler is installed lazily on first registration and
/// kept for the app's lifetime.
@MainActor
final class QuickCaptureHotKey {
    static let shared = QuickCaptureHotKey()

    /// Fired on the main actor when the registered chord is pressed.
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = {
        // FourCharCode "OTTO"
        var out: OSType = 0
        for byte in "OTTO".utf8 { out = (out << 8) | OSType(byte) }
        return out
    }()

    private init() {}

    /// Register `shortcut` as the global chord, replacing any previous one.
    /// Returns false when the system refuses it (typically the chord is held
    /// by another app) — callers surface that in Settings.
    @discardableResult
    func register(_ shortcut: QuickCaptureShortcut) -> Bool {
        unregister()
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[QuickCapture] RegisterEventHotKey failed (%d) for %@", status, shortcut.display)
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                // Carbon delivers on the main thread; hop through the main
                // actor anyway so the compiler can prove the isolation.
                let hotKey = Unmanaged<QuickCaptureHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in hotKey.onPressed?() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
}
#endif
