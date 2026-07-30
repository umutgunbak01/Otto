import SwiftUI

/// The Otto mark from the mockup — a dotted teal-gradient ring with a
/// center dot, rotating imperceptibly slowly. 12fps is plenty.
struct BrandMark: View {
    var size: CGFloat = 20

    private var tealGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.710, green: 0.961, blue: 0.902), // #b5f5e6
                Color(red: 0.369, green: 0.918, blue: 0.831), // #5eead4
                Color(red: 0.169, green: 0.749, blue: 0.643), // #2bbfa4
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            // Dotted ring (mockup: dasharray 1.1 4.45, round caps).
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let angle = (t.truncatingRemainder(dividingBy: 40) / 40) * 360
                Circle()
                    .stroke(
                        tealGradient,
                        style: StrokeStyle(
                            lineWidth: max(1.4, size * 0.095),
                            lineCap: .round,
                            dash: [size * 0.005, size * 0.031].map { max($0, 0.1) }
                        )
                    )
                    .padding(size * 0.14)
                    .rotationEffect(.degrees(angle))
            }

            // Center dot.
            Circle()
                .fill(tealGradient)
                .frame(width: max(2.5, size * 0.11), height: max(2.5, size * 0.11))
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
