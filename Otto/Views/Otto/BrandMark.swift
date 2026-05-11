import SwiftUI

/// Two concentric cyan rings — outer solid, inner dashed and slowly spinning.
/// 14s rotation, so 12fps is more than enough.
struct BrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            // Static outer ring.
            Circle()
                .stroke(Theme.Colors.cyan, lineWidth: 1.5)
                .shadow(color: Theme.Colors.cyanGlow.opacity(0.65), radius: 6)

            // Animated dashed inner ring.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let angle = (t.truncatingRemainder(dividingBy: 14) / 14) * 360
                Circle()
                    .strokeBorder(
                        Theme.Colors.cyan,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .padding(6)
                    .rotationEffect(.degrees(angle))
            }

            // Static glow dot.
            Circle()
                .fill(Theme.Colors.cyan)
                .frame(width: size * 0.08, height: size * 0.08)
                .shadow(color: Theme.Colors.cyanGlow, radius: 4)
        }
        .frame(width: size, height: size)
    }
}

/// Pulsing status dot — green pip used in the top-bar SYNC indicator.
/// Visual change is slow (1.4s cycle), 12fps is fine.
struct PulseDot: View {
    var color: Color = Theme.Colors.green
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.4) / 1.4
            let s = 0.85 + 0.15 * sin(phase * .pi * 2)
            let o = 0.5 + 0.5 * sin(phase * .pi * 2)

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(s)
                .opacity(o)
                .shadow(color: color.opacity(0.8), radius: size * 0.6)
        }
    }
}

/// Hex pip — used as the "HOME" sidebar icon (and other generic hex markers).
struct HexPip: View {
    var size: CGFloat = 10
    var color: Color = Theme.Colors.cyan

    var body: some View {
        HexagonShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

private struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.25))
        p.addLine(to: CGPoint(x: w, y: h * 0.75))
        p.addLine(to: CGPoint(x: w * 0.5, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.75))
        p.addLine(to: CGPoint(x: 0, y: h * 0.25))
        p.closeSubpath()
        return p
    }
}
