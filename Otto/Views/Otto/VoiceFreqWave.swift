import SwiftUI

/// Animated equalizer bars at the bottom of the main HUD. Was previously an
/// `HStack` of 30 `LinearGradient`+`Capsule` views rebuilt at 30fps — replaced
/// with a single `Canvas` that paints all 30 bars in one pass.
struct VoiceFreqWave: View {
    @Environment(AppState.self) private var appState
    var bars: Int = 30
    var height: CGFloat = 50

    var body: some View {
        // 24fps is plenty for an audio meter; the bars are short enough that
        // higher framerates are imperceptible.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
            Canvas { canvas, size in
                let time = ctx.date.timeIntervalSinceReferenceDate
                let level = max(0.2, CGFloat(appState.voice.inputLevel))
                let spacing: CGFloat = 3
                let barWidth = (size.width - CGFloat(bars - 1) * spacing) / CGFloat(bars)

                let cyan = Theme.Colors.cyan
                let gradient = Gradient(colors: [cyan, cyan.opacity(0)])

                for i in 0..<bars {
                    let phase = (time + Double(i) * 0.07).truncatingRemainder(dividingBy: 1.8) / 1.8
                    let s = abs(sin(phase * .pi))
                    let h = size.height * (0.12 + 0.8 * CGFloat(s) * level)
                    let x = CGFloat(i) * (barWidth + spacing)
                    let y = size.height - h

                    let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: 1)
                    canvas.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                }
            }
            .frame(height: height)
            .shadow(color: Theme.Colors.cyanGlow.opacity(0.3), radius: 4)
        }
    }
}
