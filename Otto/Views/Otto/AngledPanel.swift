import SwiftUI

// MARK: - Panel shape
//
// The redesign has no angled cuts — every panel is a rounded-rect card with
// a hairline border. `AngledCut` and `AngledPanelShape` keep their names and
// associated values so the many existing call sites compile unchanged; the
// former bevel size now just informs the corner radius (clamped to the
// mockup's 12px maximum).

enum AngledCut: Equatable {
    case topRight(CGFloat)
    case topRightBottomLeft(CGFloat)
    case rightRail(CGFloat)
    case all(CGFloat)
    case dockTop(CGFloat)
    case parallelogram(CGFloat)
    case topbar(CGFloat)

    var radius: CGFloat {
        switch self {
        case .topRight(let c), .topRightBottomLeft(let c), .rightRail(let c),
             .all(let c), .dockTop(let c), .parallelogram(let c), .topbar(let c):
            return min(c, Theme.Radius.xl)
        }
    }
}

struct AngledPanelShape: Shape {
    var cut: AngledCut

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: cut.radius)
    }
}

// MARK: - Modifier
//
// `.angledPanel(...)` fills a rounded panel background and strokes the
// hairline border in one go.

struct AngledPanelModifier: ViewModifier {
    var cut: AngledCut
    var fill: Color
    var stroke: Color
    var strokeWidth: CGFloat
    var showInnerBorder: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cut.radius)
        return content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: strokeWidth))
            .clipShape(shape)
            .contentShape(shape)
    }
}

extension View {
    func angledPanel(
        _ cut: AngledCut,
        fill: Color = Theme.Colors.panel,
        stroke: Color = Theme.Colors.border,
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
