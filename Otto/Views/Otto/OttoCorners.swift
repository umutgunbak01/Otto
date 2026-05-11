import SwiftUI

/// Four cyan corner brackets inset from the edges of a panel — the
/// `.corners::before/::after` flourishes from the mockup's main HUD frame.
struct OttoCorners: View {
    var inset: CGFloat = 8
    var size: CGFloat = 22
    var thickness: CGFloat = 1.5
    var color: Color = Theme.Colors.cyan

    var body: some View {
        ZStack {
            corner(.topLeading)
            corner(.topTrailing)
            corner(.bottomLeading)
            corner(.bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func corner(_ alignment: Alignment) -> some View {
        let path = CornerBracketShape(corner: alignment, length: size)
        path
            .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .square))
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(inset)
    }
}

private struct CornerBracketShape: Shape {
    var corner: Alignment
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch corner {
        case .topLeading:
            p.move(to: CGPoint(x: 0, y: length))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: length, y: 0))
        case .topTrailing:
            p.move(to: CGPoint(x: rect.width - length, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: length))
        case .bottomLeading:
            p.move(to: CGPoint(x: 0, y: rect.height - length))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.addLine(to: CGPoint(x: length, y: rect.height))
        case .bottomTrailing:
            p.move(to: CGPoint(x: rect.width - length, y: rect.height))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - length))
        default:
            break
        }
        return p
    }
}
