import SwiftUI

/// Ambient backdrop — radial gradient + animated grid + scanline + vignette.
///
/// Performance considerations
/// -------------------------
/// The grid + scanline are easily the hottest views in the app — they cover
/// the full window. To keep them cheap:
///   * The background gradients are drawn once as static SwiftUI views, never
///     redrawn.
///   * The grid is a single `Canvas` redrawn at 12fps (perceptually smooth at
///     these line densities) inside its own scoped `TimelineView`. No
///     clipping passes, no repeated stroke layers — one stroke pass over the
///     full path with a faint cyan tint and a soft `.blur` masking the edges.
///   * The scanline is a single shifted gradient at 20fps; uses cheap
///     translation only.
///   * The vignette is a static, pre-rasterised radial gradient. It does not
///     animate.
///
/// Stack this behind everything in `MainView`.

struct GridBackground: View {
    var body: some View {
        ZStack {
            // Ambient layer — completely static.
            LinearGradient(
                colors: [Theme.Colors.bg0, Theme.Colors.bg1],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Theme.Colors.cyan.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 0,
                endRadius: 700
            )
            RadialGradient(
                colors: [Theme.Colors.red.opacity(0.05), .clear],
                center: UnitPoint(x: 0.85, y: 0.95),
                startRadius: 0,
                endRadius: 500
            )

            // Drifting grid — single stroke pass, masked by a soft blur.
            GridLinesView()

            // Scanline.
            ScanlineView()
                .blendMode(.plusLighter)

            // Vignette — static dark overlay around the edges.
            RadialGradient(
                colors: [.clear, .clear, Color.black.opacity(0.85)],
                center: .center,
                startRadius: 100,
                endRadius: 900
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .drawingGroup()  // off-screen rasterise the whole stack each frame
    }
}

private struct GridLinesView: View {
    private let cell: CGFloat = 48

    var body: some View {
        // 12fps is plenty for a slow 18s drift.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            Canvas { canvas, size in
                let now = ctx.date.timeIntervalSinceReferenceDate
                let t = CGFloat(now.truncatingRemainder(dividingBy: 18) / 18.0)
                let dx = t * cell
                let dy = t * cell

                var path = Path()
                var x = -cell + dx
                while x < size.width + cell {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += cell
                }
                var y = -cell + dy
                while y < size.height + cell {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += cell
                }
                // One pass, faint cyan.
                canvas.stroke(
                    path,
                    with: .color(Theme.Colors.cyan.opacity(0.06)),
                    lineWidth: 1
                )
            }
            // Soft radial fade — applied as a mask once, no per-frame clip.
            .mask(
                RadialGradient(
                    colors: [.black, .black.opacity(0.7), .clear],
                    center: .center,
                    startRadius: 100,
                    endRadius: 900
                )
            )
        }
        .allowsHitTesting(false)
    }
}

private struct ScanlineView: View {
    private let bandHeight: CGFloat = 120
    private let period: Double = 6.0   // seconds per sweep

    var body: some View {
        // The scanline only translates — 20fps is more than enough.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
            GeometryReader { geo in
                let height = geo.size.height
                let now = ctx.date.timeIntervalSinceReferenceDate
                let t = CGFloat(now.truncatingRemainder(dividingBy: period) / period)
                let y = -bandHeight + t * (height + bandHeight * 2)
                let opacity: Double = {
                    if t < 0.1 { return Double(t / 0.1) }
                    if t > 0.9 { return Double((1 - t) / 0.1) }
                    return 1.0
                }()

                LinearGradient(
                    colors: [.clear, Theme.Colors.cyan.opacity(0.08), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: bandHeight)
                .offset(y: y)
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
    }
}
