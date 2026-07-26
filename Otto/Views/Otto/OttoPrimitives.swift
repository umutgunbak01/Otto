import SwiftUI

// MARK: - Cached formatters
//
// `DateFormatter` / `NumberFormatter` allocations are surprisingly expensive
// when invoked in TimelineView bodies, so we keep one instance per format.

enum OttoFormatters {
    /// Decimal formatter using a `.` thousands separator.
    static let dottedThousands: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()

    /// Standard decimal formatter — comma thousands. Used by the top-bar
    /// indexed count.
    static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// "EEE · MMM d · HH:mm" — for the Next Event card.
    static let eventDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d · HH:mm"
        return f
    }()

    /// "HHmm · MMM · dd" — legacy HUD sector label.
    static let sectorDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm · MMM · dd"
        return f
    }()

    /// Compact social-metric count — "842", "1.2K", "34K", "1.5M".
    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return String(format: v >= 10 ? "%.0fM" : "%.1fM", v)
        }
        if n >= 1_000 {
            let v = Double(n) / 1_000
            return String(format: v >= 10 ? "%.0fK" : "%.1fK", v)
        }
        return "\(n)"
    }
}

// MARK: - OttoDivider
//
// Hairline divider. The redesign has no dashed or gradient rules — every
// variant renders the same 1px hairline so legacy call sites (`.dashed`,
// `.gradient`) just get the new look.

struct OttoDivider: View {
    enum Kind { case solid, dashed, gradient }
    var kind: Kind = .solid
    var color: Color = Theme.Colors.border

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

/// Vertical hairline for HStack pane splits. OttoDivider is height-1 and
/// greedy in width — dropped into an HStack it silently swallows all the
/// leftover width as an invisible gap, so splits must use this instead.
struct OttoVerticalDivider: View {
    var color: Color = Theme.Colors.border

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
    }
}

// MARK: - OttoCountBadge
//
// The mono count chip used in list-view headers (mockup .count-chip) and
// semantic-tinted variants (mockup .chip.green/.amber/…).

struct OttoCountBadge: View {
    let count: Int
    var tone: Tone = .neutral

    enum Tone { case neutral, cyan, amber, red, green }

    private var color: Color {
        switch tone {
        case .neutral: return Theme.Colors.textDim
        case .cyan:    return Theme.Colors.accentText
        case .amber:   return Theme.Colors.amber
        case .red:     return Theme.Colors.red
        case .green:   return Theme.Colors.green
        }
    }

    private var bg: Color {
        switch tone {
        case .neutral: return Color.clear
        case .cyan:    return Theme.Colors.selectTint
        case .amber:   return Theme.Colors.tintAmber
        case .red:     return Theme.Colors.tintRed
        case .green:   return Theme.Colors.tintGreen
        }
    }

    var body: some View {
        Text(formatted)
            .font(Theme.Typography.monoSmall)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tone == .neutral ? Theme.Colors.textDim : color)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        tone == .neutral ? Theme.Colors.border : color.opacity(0.0),
                        lineWidth: 1
                    )
            )
    }

    private var formatted: String {
        OttoFormatters.decimal.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - OttoListHeader
//
// The mockup's viewbar formula: sans title + mono count chip + trailing
// controls, closed with a hairline. Replaces the old glowing mono header.

struct OttoListHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    var tone: OttoCountBadge.Tone = .neutral
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)
                if let count = count {
                    OttoCountBadge(count: count, tone: tone)
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.md)

            OttoDivider()
        }
    }
}

extension OttoListHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, tone: OttoCountBadge.Tone = .neutral) {
        self.title = title
        self.count = count
        self.tone = tone
        self.trailing = { EmptyView() }
    }
}

// MARK: - OttoRow background
//
// Uniform hover/selection treatment for list rows — rounded tint, no bars.

struct OttoRowBackground: ViewModifier {
    var isSelected: Bool = false
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(
                        isSelected
                            ? Theme.Colors.selectTint
                            : (isHovered ? Theme.Colors.hoverTint : Color.clear)
                    )
            )
    }
}

extension View {
    func ottoRow(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        modifier(OttoRowBackground(isSelected: isSelected, isHovered: isHovered))
    }
}

// MARK: - AngularChip
//
// Generic small tag chip (mockup .tag) — despite the legacy name, it's now
// a rounded 4px chip.

struct AngularChip<Content: View>: View {
    var stroke: Color = .clear
    var fill: Color = Theme.Colors.hoverTint
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(stroke, lineWidth: stroke == .clear ? 0 : 1)
            )
    }
}
