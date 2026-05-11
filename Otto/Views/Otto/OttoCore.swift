import SwiftUI

/// The centerpiece of the Otto HUD — three concentric rings with tick marks,
/// a hexagonal frame, a glowing core. Performance-tuned:
///
///   * Static elements (tick marks, compass labels, crosshair, hex frame
///     outlines) live OUTSIDE the rotating `TimelineView` and never redraw.
///   * Three rotation animations and the core pulse share a single
///     `TimelineView` tick at 24fps; the inner `Canvas`/views read the
///     phase from one timeline rather than nesting timelines.
///   * The tick ring is drawn once into a `Canvas` and stored as part of the
///     static layer; rotation is applied by the parent `rotationEffect`.
///
struct OttoCore: View {
    var size: CGFloat = 360

    var body: some View {
        ZStack {
            // -- Static layer (drawn once, no animation cost) --
            StaticOttoCoreLayer(size: size)

            // -- Animated layer --
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let slow = (t.truncatingRemainder(dividingBy: 22) / 22) * 360       // 22s
                let rev  = (t.truncatingRemainder(dividingBy: 14) / 14) * -360      // 14s reversed
                let fast = (t.truncatingRemainder(dividingBy:  9) /  9) * 360       // 9s
                let pulsePhase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
                let pulse = 1.0 + 0.05 * sin(pulsePhase * .pi * 2)
                let bright = 0.5 + 0.5 * sin(pulsePhase * .pi * 2)

                ZStack {
                    // Outer cardinal pips ring (rotating).
                    ZStack {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(Theme.Colors.cyan)
                                .frame(width: 6, height: 6)
                                .offset(y: -size / 2)
                                .rotationEffect(.degrees(Double(i) * 90))
                        }
                    }
                    .rotationEffect(.degrees(slow))

                    // Tick ring rotation.
                    StaticTickRing(radius: size * 0.42, count: 60)
                        .rotationEffect(.degrees(rev))

                    // Dashed mid ring.
                    Circle()
                        .strokeBorder(
                            Theme.Colors.cyan.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 8])
                        )
                        .frame(width: size * 0.75, height: size * 0.75)
                        .rotationEffect(.degrees(fast))

                    // Hex frames.
                    ZStack {
                        HexFrame()
                            .stroke(Theme.Colors.cyan.opacity(0.4), lineWidth: 0.8)
                            .frame(width: size * 0.66, height: size * 0.58)
                        HexFrame()
                            .stroke(Theme.Colors.cyan.opacity(0.6), lineWidth: 0.8)
                            .frame(width: size * 0.44, height: size * 0.38)
                    }
                    .rotationEffect(.degrees(slow))

                    // Glowing core.
                    OttoCoreVisual(size: size * 0.305)
                        .scaleEffect(pulse)
                        .brightness(bright * 0.2)
                }
            }
        }
        .frame(width: size + 60, height: size + 60)
        .drawingGroup()
    }
}

// MARK: - Static reactor chrome
//
// Everything that doesn't need to redraw — outer ring, mid solid ring, inner
// rings, compass labels, crosshair. Drawn once.

private struct StaticOttoCoreLayer: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            // Outer ring.
            Circle()
                .stroke(Theme.Colors.cyan.opacity(0.5), lineWidth: 1)
                .frame(width: size, height: size)

            // Mid solid ring (under the rotating tick ring).
            Circle()
                .stroke(Theme.Colors.cyan.opacity(0.5), lineWidth: 1)
                .frame(width: size * 0.89, height: size * 0.89)

            // Inner glow ring (blurred for bloom).
            Circle()
                .stroke(Theme.Colors.cyan, lineWidth: 2)
                .frame(width: size * 0.5, height: size * 0.5)
                .blur(radius: 1.5)

            Circle()
                .stroke(Theme.Colors.cyan, lineWidth: 1.2)
                .frame(width: size * 0.5, height: size * 0.5)

            // Reticle direction labels.
            let r = size / 2 + 5
            CompassLabel("N · 000").offset(y: -r)
            CompassLabel("E · 090").offset(x: r)
            CompassLabel("S · 180").offset(y: r)
            CompassLabel("W · 270").offset(x: -r)

            // Crosshair ticks.
            CrosshairTicks(size: size)
        }
    }
}

// MARK: - Tick ring
//
// 60 radial ticks. Drawn into a single `Canvas` — much cheaper than 60
// individual `Line` views. The ring itself is static; the parent applies
// rotation.

private struct StaticTickRing: View {
    var radius: CGFloat
    var count: Int

    var body: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            var longPath = Path()
            var shortPath = Path()
            for i in 0..<count {
                let long = i % 5 == 0
                let angle = Double(i) * (360.0 / Double(count)) * .pi / 180
                let r1 = radius
                let r2 = radius - (long ? 10 : 5)
                let x1 = center.x + sin(angle) * r1
                let y1 = center.y - cos(angle) * r1
                let x2 = center.x + sin(angle) * r2
                let y2 = center.y - cos(angle) * r2
                if long {
                    longPath.move(to: CGPoint(x: x1, y: y1))
                    longPath.addLine(to: CGPoint(x: x2, y: y2))
                } else {
                    shortPath.move(to: CGPoint(x: x1, y: y1))
                    shortPath.addLine(to: CGPoint(x: x2, y: y2))
                }
            }
            ctx.stroke(longPath,  with: .color(Theme.Colors.cyan.opacity(0.9)), lineWidth: 1.2)
            ctx.stroke(shortPath, with: .color(Theme.Colors.cyan.opacity(0.5)), lineWidth: 0.6)
        }
    }
}

// MARK: - Hex frame
private struct HexFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.25, y: 0))
        p.addLine(to: CGPoint(x: w * 0.75, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.5))
        p.addLine(to: CGPoint(x: w * 0.75, y: h))
        p.addLine(to: CGPoint(x: w * 0.25, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.5))
        p.closeSubpath()
        return p
    }
}

// MARK: - Compass label
private struct CompassLabel: View {
    let text: String
    init(_ t: String) { self.text = t }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(Theme.Colors.cyan.opacity(0.8))
    }
}

// MARK: - Crosshair ticks
private struct CrosshairTicks: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(Theme.Colors.cyan)
                    .frame(width: size * 0.083, height: 0.8)
                    .offset(x: size * 0.18)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
    }
}

// MARK: - Core (no internal TimelineView — driven by parent)
//
// The pulse and brightness are applied by the parent OttoCore's TimelineView.

struct OttoCoreVisual: View {
    var size: CGFloat = 110
    var label: String = "OTTO"

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.aiAccent,
                            Theme.Colors.cyan,
                            Theme.Colors.cyanDim,
                            Theme.Colors.cyan.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 1.4
                    )
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.6), lineWidth: 0.5)
                        .blur(radius: 1)
                        .padding(3)
                )
                .shadow(color: Theme.Colors.cyanGlow, radius: 30)

            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Colors.bg0)
                .shadow(color: .white, radius: 4)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Backwards-compat wrapper
//
// The old code referenced `OttoCoreOverlay` directly; keep the symbol so we
// don't break anything that might import it.

struct OttoCoreOverlay: View {
    var size: CGFloat = 110
    var label: String = "OTTO"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
            let pulse = 1.0 + 0.05 * sin(phase * .pi * 2)
            let bright = 1.0 + 0.2 * (0.5 + 0.5 * sin(phase * .pi * 2))
            OttoCoreVisual(size: size, label: label)
                .scaleEffect(pulse)
                .brightness((bright - 1.0) * 0.2)
        }
    }
}
