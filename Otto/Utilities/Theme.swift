import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Design System
//
// Tokens follow otto-redesign-mockup.html: calm dark surfaces, hairline
// borders, one cyan accent, semantic green/amber/red/violet. Sans-serif for
// UI text; monospace reserved for data (counts, dates, domains, handles).
// Legacy HUD symbol names (cyan, cyanGlow, panelEdge, …) are kept as aliases
// so existing views pick up the new palette without call-site edits.

enum Theme {
    // Colors — mockup dark palette
    enum Colors {
        // Surfaces
        static let bgPage              = Color(red: 0.031, green: 0.035, blue: 0.039) // #08090a
        static let bg0                 = Color(red: 0.043, green: 0.047, blue: 0.055) // #0b0c0e
        static let bg1                 = Color(red: 0.055, green: 0.059, blue: 0.071) // #0e0f12
        static let bg2                 = Color(red: 0.071, green: 0.075, blue: 0.086) // #121316
        static let bgInput             = Color(red: 0.086, green: 0.090, blue: 0.106) // #16171b

        // Backwards-compatible aliases used by existing list views.
        static let background          = bg0
        static let secondaryBackground = bg2
        static let sidebar             = bg1
        static let elevatedSurface     = Color.white.opacity(0.045)

        // Accent — the mockup's single cyan. `cyanGlow` is intentionally
        // clear: the redesign has no glows, and pointing the alias at clear
        // switches every legacy `.shadow(color: cyanGlow…)` off at once.
        static let cyan                = Color(red: 0.369, green: 0.780, blue: 0.910) // #5ec7e8
        static let cyanDim             = Color(red: 0.282, green: 0.600, blue: 0.702) // #4899b3
        static let cyanGlow            = Color.clear
        static let accentText          = Color(red: 0.490, green: 0.839, blue: 0.941) // #7dd6f0
        static let onAccent            = Color(red: 0.024, green: 0.129, blue: 0.169) // #06212b

        // Status accents
        static let amber               = Color(red: 0.949, green: 0.694, blue: 0.333) // #f2b155
        static let red                 = Color(red: 0.949, green: 0.416, blue: 0.510) // #f26a82
        static let green               = Color(red: 0.290, green: 0.871, blue: 0.502) // #4ade80
        static let violet              = Color(red: 0.706, green: 0.573, blue: 0.910) // #b492e8

        // Semantic tints — chip backgrounds.
        static let tintGreen           = green.opacity(0.12)
        static let tintAmber           = amber.opacity(0.12)
        static let tintRed             = red.opacity(0.12)
        static let tintViolet          = violet.opacity(0.12)

        // Text
        static let text                = Color(red: 0.914, green: 0.918, blue: 0.925) // #e9eaec
        static let textDim             = Color(red: 0.604, green: 0.608, blue: 0.639) // #9a9ba3
        static let secondaryText       = textDim
        static let tertiaryText        = Color(red: 0.373, green: 0.380, blue: 0.412) // #5f6169

        // Panels & borders — hairline whites, never cyan.
        static let panel               = bg2
        static let panelEdge           = Color.white.opacity(0.07)
        static let gridLine            = Color.white.opacity(0.04)
        static let border              = Color.white.opacity(0.07)
        static let borderStrong        = Color.white.opacity(0.13)
        static let borderSubtle        = Color.white.opacity(0.045)
        /// Hover/highlight tint over dark panels.
        static let hoverTint           = Color.white.opacity(0.045)
        /// Selection tint (accent-tinted, matches mockup --bg-active).
        static let selectTint          = Color(red: 0.369, green: 0.780, blue: 0.910).opacity(0.10)
        /// User chat bubble surface.
        static let userBubble          = Color(red: 0.102, green: 0.110, blue: 0.129) // #1a1c21

        // Brand aliases — the rest of the codebase still references these.
        static let accent              = cyan
        static let aiAccent            = accentText

        // Priority colors
        static let priorityUrgent      = red
        static let priorityHigh        = amber
        static let priorityMedium      = cyan.opacity(0.65)
        static let priorityLow         = textDim

        // Category colors
        static let work                = cyan
        static let personal            = green
        static let hobby               = violet
    }

    // Typography — sans-serif for UI, monospace only for data (counts,
    // dates, domains, handles, chips). The `mono*` set exists for those
    // data displays; `label` stays mono because it renders uppercase
    // group/section labels exactly like the mockup's .group-label.
    enum Typography {
        #if os(macOS)
        static let largeTitle = Font.system(size: 26, weight: .bold)
        static let title      = Font.system(size: 16, weight: .semibold)
        static let headline   = Font.system(size: 13.5, weight: .semibold)
        static let body       = Font.system(size: 13, weight: .regular)
        static let callout    = Font.system(size: 12, weight: .regular)
        static let caption    = Font.system(size: 11, weight: .regular)
        static let small      = Font.system(size: 10, weight: .medium)
        static let label      = Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let timer      = Font.system(size: 28, weight: .semibold, design: .monospaced)

        static let monoBody    = Font.system(size: 12, weight: .regular,  design: .monospaced)
        static let monoCaption = Font.system(size: 11, weight: .regular,  design: .monospaced)
        static let monoSmall   = Font.system(size: 10.5, weight: .medium, design: .monospaced)
        #else
        static let largeTitle = Font.system(size: 28, weight: .bold)
        static let title      = Font.system(size: 18, weight: .semibold)
        static let headline   = Font.system(size: 15, weight: .semibold)
        static let body       = Font.system(size: 14, weight: .regular)
        static let callout    = Font.system(size: 13, weight: .regular)
        static let caption    = Font.system(size: 12, weight: .regular)
        static let small      = Font.system(size: 10, weight: .medium)
        static let label      = Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let timer      = Font.system(size: 28, weight: .semibold, design: .monospaced)

        static let monoBody    = Font.system(size: 13, weight: .regular,  design: .monospaced)
        static let monoCaption = Font.system(size: 12, weight: .regular,  design: .monospaced)
        static let monoSmall   = Font.system(size: 10.5, weight: .medium, design: .monospaced)
        #endif
    }

    // Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // Corner Radius — mockup: 6 / 8 / 12.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
        static let full: CGFloat = 999
    }

    // Letter spacing — used only on mono uppercase labels now, so the values
    // are far tighter than the old HUD (mockup: .12em of 10px ≈ 1.2).
    enum Tracking {
        static let tight: CGFloat = 0.2
        static let normal: CGFloat = 0.4
        static let wide: CGFloat = 0.8
        static let xwide: CGFloat = 1.2
        static let xxwide: CGFloat = 1.6
    }
}

// MARK: - View Extensions

extension View {
    func sidebarItem(isSelected: Bool = false) -> some View {
        self
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isSelected ? Theme.Colors.selectTint : Color.clear)
            )
            .foregroundStyle(isSelected ? Theme.Colors.accentText : Theme.Colors.textDim)
    }

    func cardStyle() -> some View {
        self
            .background(Theme.Colors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    func aiCardStyle() -> some View {
        self
            .background(Theme.Colors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.accent.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    /// Legacy glow hook — the redesign has no glows, so this is a no-op that
    /// keeps the ~30 call sites compiling.
    func neonGlow(color: Color = Theme.Colors.cyan, intensity: Double = 1.0) -> some View {
        self
    }

    /// Uppercase letter-spaced mono label — mockup's .group-label / card h3.
    func hudLabel(tracking: CGFloat = Theme.Tracking.xwide, color: Color = Theme.Colors.tertiaryText) -> some View {
        self
            .font(Theme.Typography.label)
            .tracking(tracking)
            .foregroundStyle(color)
            .textCase(.uppercase)
    }
}

// MARK: - Custom Button Styles

struct SidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(
                        isSelected
                            ? Theme.Colors.selectTint
                            : (configuration.isPressed ? Theme.Colors.hoverTint : Color.clear)
                    )
            )
            .foregroundStyle(isSelected ? Theme.Colors.accentText : Theme.Colors.textDim)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(configuration.isPressed ? Theme.Colors.hoverTint : Color.clear)
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Filled accent button — the mockup's .new-btn.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.Colors.accent.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .foregroundStyle(Theme.Colors.onAccent)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#if os(iOS)
struct PillButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.caption)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                isActive
                    ? Theme.Colors.selectTint
                    : Theme.Colors.bg2
            )
            .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.textDim)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
#endif

// MARK: - Haptic Feedback

#if os(iOS)
enum HapticFeedback {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
#endif

// MARK: - Cross-Platform URL Opener

func openURL(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
