import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Design System — Otto HUD

enum Theme {
    // Colors — Otto HUD palette (always dark, cyan-dominant)
    enum Colors {
        // Surfaces — deep navy / abyss
        static let bg0                 = Color(red: 0.008, green: 0.024, blue: 0.047) // #02060c
        static let bg1                 = Color(red: 0.020, green: 0.051, blue: 0.094) // #050d18
        static let bg2                 = Color(red: 0.031, green: 0.094, blue: 0.149) // #081826

        // Backwards-compatible aliases used by existing list views.
        static let background          = bg0
        static let secondaryBackground = bg2
        static let sidebar             = bg1
        static let elevatedSurface     = Color.white.opacity(0.03)

        // Cyan / glow palette
        static let cyan                = Color(red: 0.373, green: 0.906, blue: 1.000) // #5fe7ff
        static let cyanDim             = Color(red: 0.165, green: 0.663, blue: 0.784) // #2aa9c8
        static let cyanGlow            = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.65)

        // Status accents
        static let amber               = Color(red: 1.000, green: 0.702, blue: 0.278) // #ffb347
        static let red                 = Color(red: 1.000, green: 0.333, blue: 0.447) // #ff5572
        static let green               = Color(red: 0.373, green: 1.000, blue: 0.663) // #5fffa9

        // Text — pale aqua white scale
        static let text                = Color(red: 0.812, green: 0.918, blue: 0.961) // #cfeaf5
        static let textDim             = Color(red: 0.435, green: 0.541, blue: 0.604) // #6f8a9a
        static let secondaryText       = textDim
        static let tertiaryText        = Color(red: 0.282, green: 0.380, blue: 0.435) // #485f6f

        // Panel surface (translucent navy with cyan edge)
        static let panel               = Color(red: 0.039, green: 0.102, blue: 0.157).opacity(0.55) // rgba(10,26,40,.55)
        static let panelEdge           = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.35)
        static let gridLine            = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.06)
        static let border              = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.18)
        /// Replaces the legacy `Color.primary.opacity(0.05)` usage scattered
        /// across list/detail views — a faint cyan tint for badge backgrounds,
        /// hover states, and subtle borders.
        static let borderSubtle        = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.07)
        /// Hover/highlight tint over the dark panel.
        static let hoverTint           = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.06)
        /// Selection tint (slightly more opaque than hover).
        static let selectTint          = Color(red: 0.373, green: 0.906, blue: 1.000).opacity(0.12)

        // Brand aliases — the rest of the codebase still references these.
        static let accent              = cyan                       // primary cyan
        static let aiAccent            = Color(red: 0.682, green: 0.961, blue: 1.000) // #aef5ff (light cyan core)

        // Priority colors (re-mapped to the Otto palette)
        static let priorityUrgent      = red
        static let priorityHigh        = amber
        static let priorityMedium      = cyan.opacity(0.65)
        static let priorityLow         = textDim

        // Category colors — kept for compatibility with existing views, retinted to Otto hues.
        static let work                = cyan
        static let personal            = green
        static let hobby               = Color(red: 0.847, green: 0.557, blue: 1.000) // muted violet
    }

    // Typography — JetBrains Mono / SF Mono everywhere. The Otto HUD uses
    // monospace exclusively; numerals get tabular figures so timers don't jitter.
    enum Typography {
        #if os(macOS)
        static let largeTitle = Font.system(size: 24, weight: .bold,     design: .monospaced)
        static let title      = Font.system(size: 16, weight: .semibold, design: .monospaced)
        static let headline   = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let body       = Font.system(size: 12, weight: .regular,  design: .monospaced)
        static let callout    = Font.system(size: 11, weight: .regular,  design: .monospaced)
        static let caption    = Font.system(size: 10, weight: .regular,  design: .monospaced)
        static let small      = Font.system(size:  9, weight: .medium,   design: .monospaced)
        // Otto-specific: "letter-spaced label" — used for HUD labels in caps.
        static let label      = Font.system(size:  9, weight: .semibold, design: .monospaced)
        static let timer      = Font.system(size: 32, weight: .bold,     design: .monospaced)
        #else
        static let largeTitle = Font.system(size: 28, weight: .bold,     design: .monospaced)
        static let title      = Font.system(size: 18, weight: .semibold, design: .monospaced)
        static let headline   = Font.system(size: 15, weight: .semibold, design: .monospaced)
        static let body       = Font.system(size: 14, weight: .regular,  design: .monospaced)
        static let callout    = Font.system(size: 13, weight: .regular,  design: .monospaced)
        static let caption    = Font.system(size: 12, weight: .regular,  design: .monospaced)
        static let small      = Font.system(size: 10, weight: .medium,   design: .monospaced)
        static let label      = Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let timer      = Font.system(size: 32, weight: .bold,     design: .monospaced)
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

    // Corner Radius — Otto prefers angled cuts via AngledPanel,
    // but rounded radii are still used for chips, dropdowns, and legacy cards.
    enum Radius {
        static let sm: CGFloat = 2
        static let md: CGFloat = 4
        static let lg: CGFloat = 6
        static let xl: CGFloat = 10
        static let xxl: CGFloat = 14
        static let full: CGFloat = 999
    }

    // Letter spacing constants used across the HUD text.
    enum Tracking {
        static let tight: CGFloat = 0.5
        static let normal: CGFloat = 1.0
        static let wide: CGFloat = 2.0
        static let xwide: CGFloat = 3.0
        static let xxwide: CGFloat = 4.5
    }
}

// MARK: - View Extensions

extension View {
    func sidebarItem(isSelected: Bool = false) -> some View {
        self
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                isSelected
                    ? LinearGradient(
                        colors: [Theme.Colors.cyan.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Theme.Colors.cyan : .clear)
                    .frame(width: 2)
            }
            .foregroundStyle(isSelected ? Theme.Colors.cyan : Theme.Colors.textDim)
            .shadow(color: isSelected ? Theme.Colors.cyanGlow.opacity(0.40) : .clear, radius: 6,  x: 0, y: 0)
    }

    func cardStyle() -> some View {
        self
            .background(Theme.Colors.panel)
            .overlay(
                Rectangle()
                    .strokeBorder(Theme.Colors.panelEdge, lineWidth: 1)
            )
    }

    func aiCardStyle() -> some View {
        self
            .background(Theme.Colors.panel)
            .overlay(
                Rectangle()
                    .strokeBorder(Theme.Colors.cyan.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Theme.Colors.cyanGlow.opacity(0.18), radius: 8,  x: 0, y: 0)
            .shadow(color: Theme.Colors.cyan.opacity(0.10),     radius: 20, x: 0, y: 4)
    }

    /// Two-layer neon glow — tight edge + wide bloom.
    func neonGlow(color: Color = Theme.Colors.cyan, intensity: Double = 1.0) -> some View {
        self
            .shadow(color: color.opacity(0.55 * intensity), radius: 6,  x: 0, y: 0)
            .shadow(color: color.opacity(0.25 * intensity), radius: 14, x: 0, y: 0)
    }

    /// Apply uppercase letter-spaced HUD treatment to a text view.
    func hudLabel(tracking: CGFloat = Theme.Tracking.xwide, color: Color = Theme.Colors.textDim) -> some View {
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
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    if isSelected {
                        LinearGradient(
                            colors: [Theme.Colors.cyan.opacity(0.18), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else if configuration.isPressed {
                        Theme.Colors.cyan.opacity(0.06)
                    } else {
                        Color.clear
                    }
                }
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected
                          ? Theme.Colors.cyan
                          : configuration.isPressed
                            ? Theme.Colors.cyan.opacity(0.4)
                            : .clear)
                    .frame(width: 2)
            }
            .foregroundStyle(isSelected ? Theme.Colors.cyan : Theme.Colors.text)
            .shadow(color: isSelected ? Theme.Colors.cyanGlow.opacity(0.40) : .clear, radius: 6,  x: 0, y: 0)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(configuration.isPressed ? Theme.Colors.cyan.opacity(0.08) : Color.clear)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.cyan.opacity(0.12))
            .overlay(
                Rectangle()
                    .strokeBorder(Theme.Colors.cyan, lineWidth: 1)
            )
            .foregroundStyle(Theme.Colors.cyan)
            .shadow(
                color: Theme.Colors.cyanGlow.opacity(configuration.isPressed ? 0.30 : 0.55),
                radius: configuration.isPressed ? 4 : 8, x: 0, y: 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
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
                    ? Theme.Colors.cyan.opacity(0.15)
                    : Theme.Colors.bg2
            )
            .foregroundStyle(isActive ? Theme.Colors.cyan : Theme.Colors.textDim)
            .clipShape(Capsule())
            .shadow(color: isActive ? Theme.Colors.cyanGlow.opacity(0.35) : .clear, radius: 6, x: 0, y: 0)
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
