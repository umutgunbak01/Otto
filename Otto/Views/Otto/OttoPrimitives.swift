import SwiftUI

// MARK: - Cached formatters
//
// `DateFormatter` / `NumberFormatter` allocations are surprisingly expensive
// when invoked in TimelineView bodies. The Otto HUD calls these dozens of
// times per second, so we keep one instance per format and reuse it.

enum OttoFormatters {
    /// Decimal formatter using a `.` thousands separator (matches the
    /// "8.351" mockup style for sidebar count chips).
    static let dottedThousands: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()

    /// Standard decimal formatter — comma thousands. Used by INDEX in the
    /// top-bar.
    static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// "EEE · MMM d · HH:mm" — for the Next Event panel.
    static let eventDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d · HH:mm"
        return f
    }()

    /// "HHmm · MMM · dd" — for the SECTOR label on the home HUD.
    static let sectorDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm · MMM · dd"
        return f
    }()
}

// MARK: - OttoDivider
//
// Cyan dashed divider that replaces system `Divider()` in the list/detail
// views. Defaults to a tight dashed style matching the mockup; can be solid
// for tighter areas.

struct OttoDivider: View {
    enum Kind { case solid, dashed, gradient }
    var kind: Kind = .solid
    var color: Color = Theme.Colors.cyan.opacity(0.18)

    var body: some View {
        switch kind {
        case .solid:
            Rectangle()
                .fill(color)
                .frame(height: 1)
        case .dashed:
            DashedLine()
                .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
        case .gradient:
            LinearGradient(
                colors: [.clear, color, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }
}

// MARK: - OttoCountBadge
//
// The cyan-bordered count chip used in list-view headers ("To-Dos · 12").
// Shapes match the sidebar nav-item count chip — angular, not capsule.

struct OttoCountBadge: View {
    let count: Int
    var tone: Tone = .neutral

    enum Tone { case neutral, cyan, amber, red, green }

    private var color: Color {
        switch tone {
        case .neutral: return Theme.Colors.textDim
        case .cyan:    return Theme.Colors.cyan
        case .amber:   return Theme.Colors.amber
        case .red:     return Theme.Colors.red
        case .green:   return Theme.Colors.green
        }
    }

    private var bg: Color {
        switch tone {
        case .neutral: return Theme.Colors.borderSubtle
        case .cyan:    return Theme.Colors.cyan.opacity(0.15)
        case .amber:   return Theme.Colors.amber.opacity(0.15)
        case .red:     return Theme.Colors.red.opacity(0.15)
        case .green:   return Theme.Colors.green.opacity(0.15)
        }
    }

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(bg)
            .overlay(
                Rectangle().stroke(color.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - OttoListHeader
//
// Standard header for every list view — uppercased monospace title with the
// cyan glow, an angular count chip on the right, optional trailing buttons,
// and a dashed cyan baseline. Replaces the various ad-hoc Headers in
// TodoListView / NoteListView / etc.

struct OttoListHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    var tone: OttoCountBadge.Tone = .cyan
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Text("⌬ " + title.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)
                if let count = count {
                    OttoCountBadge(count: count, tone: tone)
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            OttoDivider(kind: .dashed)
        }
    }
}

extension OttoListHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, tone: OttoCountBadge.Tone = .cyan) {
        self.title = title
        self.count = count
        self.tone = tone
        self.trailing = { EmptyView() }
    }
}

// MARK: - OttoRow background
//
// View modifier used by list rows to give a uniform hover/selection
// treatment with cyan glow when active.

struct OttoRowBackground: ViewModifier {
    var isSelected: Bool = false
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                isSelected
                    ? Theme.Colors.selectTint
                    : (isHovered ? Theme.Colors.hoverTint : Color.clear)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Theme.Colors.cyan : .clear)
                    .frame(width: 2)
            }
    }
}

extension View {
    func ottoRow(isSelected: Bool = false, isHovered: Bool = false) -> some View {
        modifier(OttoRowBackground(isSelected: isSelected, isHovered: isHovered))
    }
}

// MARK: - OttoChip-style badge
//
// Generic small rectangular chip — used to replace `Capsule()` count badges
// in list headers without redoing the label/styling.

struct AngularChip<Content: View>: View {
    var stroke: Color = Theme.Colors.border
    var fill: Color = Theme.Colors.borderSubtle
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(
                Rectangle().stroke(stroke, lineWidth: 1)
            )
    }
}
