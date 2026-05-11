import SwiftUI

// MARK: - Angled (clip-path) Panel
//
// Mirrors the CSS `clip-path: polygon(...)` used throughout the Otto HUD —
// a rectangle with one or more 45° corners cut off. Three variants cover the
// shapes used in the mockup:
//
//   .topRight             — top-right corner clipped (sidebar)
//   .topLeftBottomRight   — diagonally clipped (panel, dock)
//   .all                  — all four corners clipped (main HUD frame)
//
// `cut` is the bevel size in points.

enum AngledCut: Equatable {
    /// Only top-right corner cut. Used for the left sidebar.
    case topRight(CGFloat)
    /// Top-right + bottom-left cut. Used for right-rail panels.
    case topRightBottomLeft(CGFloat)
    /// Top-right + bottom-left + bottom-right cut. Used for the right rail full panels.
    case rightRail(CGFloat)
    /// All four corners cut. Used for the main HUD frame.
    case all(CGFloat)
    /// Top-left + top-right corners (dock has angled top edge).
    case dockTop(CGFloat)
    /// Top-left + bottom-right cut (chip / prompt slash shape).
    case parallelogram(CGFloat)
    /// Top-right + bottom-right + bottom-left (top-bar style).
    case topbar(CGFloat)
}

struct AngledPanelShape: Shape {
    var cut: AngledCut

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch cut {
        case .topRight(let c):
            // (0,0) -> (W-c, 0) -> (W, c) -> (W, H) -> (0, H) -> close
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()

        case .topRightBottomLeft(let c):
            // 0,0 -> W-c,0 -> W,c -> W,H -> c,H -> 0,H-c -> close
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: c, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height - c))
            p.closeSubpath()

        case .rightRail(let c):
            // Top-right, bottom-right corners cut + bottom-left straight.
            // 0,0 -> W-c,0 -> W,c -> W,H-c -> W-c,H -> 0,H -> close
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - c))
            p.addLine(to: CGPoint(x: rect.width - c, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()

        case .all(let c):
            // c,0 -> W-c,0 -> W,c -> W,H-c -> W-c,H -> c,H -> 0,H-c -> 0,c
            p.move(to: CGPoint(x: c, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - c))
            p.addLine(to: CGPoint(x: rect.width - c, y: rect.height))
            p.addLine(to: CGPoint(x: c, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height - c))
            p.addLine(to: CGPoint(x: 0, y: c))
            p.closeSubpath()

        case .dockTop(let c):
            // 0,c -> c,0 -> W-c,0 -> W,c -> W,H -> 0,H
            p.move(to: CGPoint(x: 0, y: c))
            p.addLine(to: CGPoint(x: c, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()

        case .parallelogram(let c):
            // c,0 -> W,0 -> W-c,H -> 0,H
            p.move(to: CGPoint(x: c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()

        case .topbar(let c):
            // 0,0 -> W-c,0 -> W,c -> W,H -> c,H -> 0,H-c -> close
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width - c, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: c))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: c, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height - c))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Modifier
//
// `.angledPanel(.all(20))` clips a view to an Iron-Man HUD shape, fills the
// translucent panel background, and strokes the cyan edge in one go.

struct AngledPanelModifier: ViewModifier {
    var cut: AngledCut
    var fill: Color
    var stroke: Color
    var strokeWidth: CGFloat
    var showInnerBorder: Bool

    func body(content: Content) -> some View {
        // `AngledPanelShape` is a small struct, but its `path(in:)` allocates
        // a CG path every call. We construct the shape once per modifier
        // invocation and pass it to all four shape consumers so the path is
        // built at most four times per render rather than once per consumer
        // call site (which the compiler-generated body would otherwise do).
        let shape = AngledPanelShape(cut: cut)
        return content
            .background(shape.fill(fill))
            .background(
                showInnerBorder
                    ? AnyView(shape.stroke(Theme.Colors.cyan.opacity(0.12), lineWidth: 1).padding(2))
                    : AnyView(EmptyView())
            )
            .overlay(shape.stroke(stroke, lineWidth: strokeWidth))
            .clipShape(shape)
            .contentShape(shape)
    }
}

extension View {
    func angledPanel(
        _ cut: AngledCut,
        fill: Color = Theme.Colors.panel,
        stroke: Color = Theme.Colors.panelEdge,
        strokeWidth: CGFloat = 1,
        innerBorder: Bool = false
    ) -> some View {
        modifier(AngledPanelModifier(
            cut: cut,
            fill: fill,
            stroke: stroke,
            strokeWidth: strokeWidth,
            showInnerBorder: innerBorder
        ))
    }
}
