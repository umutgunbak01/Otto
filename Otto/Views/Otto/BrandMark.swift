import SwiftUI

/// The Otto mark from the mockup — a solid accent ring, a slowly spinning
/// dashed inner ring, and a center dot. 14s rotation, so 12fps is plenty.
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            // Static outer ring.
            Circle()
                .strokeBorder(Theme.Colors.accent.opacity(0.85), lineWidth: 1.5)

            // Animated dashed inner ring.
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let angle = (t.truncatingRemainder(dividingBy: 14) / 14) * 360
                Circle()
                    .strokeBorder(
                        Theme.Colors.accent.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .padding(size * 0.175)
                    .rotationEffect(.degrees(angle))
            }

            // Center dot.
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 3, height: 3)
        }
        .frame(width: size, height: size)
    }
}

/// Breathing status dot — the mockup's .live indicator.
struct PulseDot: View {
    var color: Color = Theme.Colors.green
    var size: CGFloat = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 2.8) / 2.8
            let s = 0.85 + 0.15 * sin(phase * .pi * 2)
            let o = 0.45 + 0.55 * (0.5 + 0.5 * sin(phase * .pi * 2))

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(s)
                .opacity(o)
        }
    }
}

/// Small dot pip — kept for legacy call sites that used the hex HOME icon.
struct HexPip: View {
    var size: CGFloat = 10
    var color: Color = Theme.Colors.accent

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
    }
}
