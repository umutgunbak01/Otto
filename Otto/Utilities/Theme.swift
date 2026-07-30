import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Design System
//
// Tokens follow otto-redesign-full.html: a near-black warm page with faint
// radial tints and film grain, alpha-white panels and hairlines, one teal
// accent plus semantic amber/green/red/violet/blue (each with a dim wash),
// serif display type for titles, monospace for data (counts, dates, domains,
// handles, overlines). Legacy symbol names (cyan, cyanGlow, panelEdge, bg0…)
// are kept as aliases so existing views pick up the new palette without
// call-site edits.

enum Theme {
    // Colors — full-redesign dark palette
    enum Colors {
        // Surfaces. The page is one near-black; panes layer alpha whites on
        // top of the shared backdrop rather than their own opaque fills.
        static let bgPage              = Color(red: 0.039, green: 0.039, blue: 0.043) // #0a0a0b
        static let bg0                 = bgPage
        static let bg1                 = Color(red: 0.051, green: 0.051, blue: 0.055) // #0d0d0e
        static let bg2                 = Color(red: 0.075, green: 0.075, blue: 0.082) // #131315
        static let bgInput             = Color(red: 0.086, green: 0.086, blue: 0.094) // #161618
        /// Opaque header fill for sticky table headers (mockup #111114).
        static let bgRaised            = Color(red: 0.067, green: 0.067, blue: 0.078) // #111114

        // Backwards-compatible aliases used by existing list views.
        static let background          = bg0
        static let secondaryBackground = bg2
        static let sidebar             = bg1
        static let elevatedSurface     = Color.white.opacity(0.045)

        // Accent — the mockup's teal. `cyanGlow` is intentionally clear:
        // the redesign has no glows, and pointing the alias at clear switches
        // every legacy `.shadow(color: cyanGlow…)` off at once.
        static let cyan                = Color(red: 0.431, green: 0.906, blue: 0.824) // #6ee7d2
        static let cyanDim             = Color(red: 0.169, green: 0.749, blue: 0.643) // #2bbfa4
        static let cyanGlow            = Color.clear
        static let accentText          = Color(red: 0.369, green: 0.918, blue: 0.831) // #5eead4
        static let onAccent            = Color(red: 0.020, green: 0.149, blue: 0.125) // #052620

        // Accent gradient endpoints (send / primary CTA fills).
        static let accentGradTop       = Color(red: 0.545, green: 0.941, blue: 0.863) // #8bf0dc
        static let accentGradBottom    = Color(red: 0.263, green: 0.812, blue: 0.706) // #43cfb4

        // Status accents
        static let amber               = Color(red: 0.941, green: 0.776, blue: 0.455) // #f0c674
        static let red                 = Color(red: 0.937, green: 0.549, blue: 0.518) // #ef8c84
        static let green               = Color(red: 0.373, green: 0.827, blue: 0.604) // #5fd39a
        static let violet              = Color(red: 0.725, green: 0.655, blue: 0.961) // #b9a7f5
        static let blue                = Color(red: 0.522, green: 0.722, blue: 0.941) // #85b8f0

        // Semantic tints — chip / icon-square washes.
        static let tintGreen           = green.opacity(0.10)
        static let tintAmber           = amber.opacity(0.10)
        static let tintRed             = red.opacity(0.10)
        static let tintViolet          = violet.opacity(0.10)
        static let tintBlue            = blue.opacity(0.10)
        static let tintTeal            = cyan.opacity(0.12)

        // Text — warm off-whites (mockup --t1/--t2/--t3).
        static let text                = Color(red: 0.957, green: 0.949, blue: 0.929) // #f4f2ed
        static let textDim             = Color(red: 0.933, green: 0.922, blue: 0.894).opacity(0.64)
        static let secondaryText       = textDim
        static let tertiaryText        = Color(red: 0.933, green: 0.922, blue: 0.894).opacity(0.40)

        // Panels & borders — hairline whites, never teal.
        static let panel               = Color.white.opacity(0.026)
        static let panel2              = Color.white.opacity(0.052)
        static let panelWash           = Color.white.opacity(0.012)
        static let panelEdge           = Color.white.opacity(0.065)
        static let gridLine            = Color.white.opacity(0.024)
        static let border              = Color.white.opacity(0.065)
        static let borderStrong        = Color.white.opacity(0.13)
        static let borderSubtle        = Color.white.opacity(0.045)
        /// Hover/highlight tint over dark panels.
        static let hoverTint           = Color.white.opacity(0.045)
        /// Selection tint (teal-washed, matches mockup --teal-dim).
        static let selectTint          = Color(red: 0.431, green: 0.906, blue: 0.824).opacity(0.10)
        /// User chat bubble surface (mockup .mu .bub uses --panel-2).
        static let userBubble          = Color.white.opacity(0.052)

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

    // Typography — sans-serif for UI text, a serif display face (New York)
    // for the big editorial titles, monospace for data (counts, dates,
    // domains, handles, overlines). Mirrors the mockup's Inter / Instrument
    // Serif / Geist Mono trio with system faces.
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

        // Serif display set — mockup's Instrument Serif moments.
        /// Hero headline ("Ask or create").
        static let displayXL   = Font.system(size: 40, weight: .regular, design: .serif)
        /// View titles (mockup .vtitle 27px).
        static let display     = Font.system(size: 25, weight: .regular, design: .serif)
        /// Briefing headline / empty-state title (mockup 23.5px).
        static let displayMd   = Font.system(size: 21, weight: .regular, design: .serif)
        /// Document titles in editors (mockup .dtitle 35px).
        static let displayLg   = Font.system(size: 31, weight: .regular, design: .serif)
        /// Inline serif italic (thinking indicator).
        static let displaySm   = Font.system(size: 13, weight: .regular, design: .serif)
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

        static let displayXL   = Font.system(size: 40, weight: .regular, design: .serif)
        static let display     = Font.system(size: 25, weight: .regular, design: .serif)
        static let displayMd   = Font.system(size: 21, weight: .regular, design: .serif)
        static let displayLg   = Font.system(size: 31, weight: .regular, design: .serif)
        static let displaySm   = Font.system(size: 13, weight: .regular, design: .serif)
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

    // Corner Radius — mockup: 6–16, cards mostly 11–14.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
        static let full: CGFloat = 999
    }

    // Letter spacing — used only on mono uppercase labels now, so the values
    // are far tighter than the old HUD (mockup overline: .2em of 9.5px ≈ 1.9).
    enum Tracking {
        static let tight: CGFloat = 0.2
        static let normal: CGFloat = 0.4
        static let wide: CGFloat = 0.8
        static let xwide: CGFloat = 1.2
        static let xxwide: CGFloat = 1.9
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

    /// Uppercase letter-spaced mono label — mockup's .ovl / .glabel.
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

/// Filled accent button — the mockup's .newbtn (teal gradient, dark ink).
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [Theme.Colors.accentGradTop, Theme.Colors.accentGradBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(configuration.isPressed ? 0.85 : 1)
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
