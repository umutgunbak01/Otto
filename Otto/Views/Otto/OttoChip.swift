import SwiftUI

/// Floating "data node" used in the main HUD — a small angled-corner badge
/// with a tiny label, a big number, and an optional sub-line.
struct OttoDataNode: View {
    enum Tone { case cyan, amber, green, red }

    let label: String
    let value: String
    let sub: String?
    var tone: Tone = .cyan

    private var color: Color {
        switch tone {
        case .cyan:  return Theme.Colors.cyan
        case .amber: return Theme.Colors.amber
        case .green: return Theme.Colors.green
        case .red:   return Theme.Colors.red
        }
    }

    var body: some View {
        // 12fps is plenty for a 6s gentle float — the eye can't see faster.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = sin(t / 6 * .pi * 2)            // 6s float cycle
            let dy = CGFloat(phase) * 4

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(2.5)
                    .foregroundStyle(Theme.Colors.textDim)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.6), radius: 4)
                if let sub = sub {
                    Text(sub)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 160, alignment: .leading)
            .angledPanel(
                .topRightBottomLeft(8),
                fill: Theme.Colors.bg1.opacity(0.85),
                stroke: color,
                strokeWidth: 1
            )
            .shadow(color: color.opacity(0.3), radius: 14)
            .offset(y: dy)
        }
    }
}

/// Suggestion chip used above the dock — sloped clip-path silhouette.
///
/// The clip shape is instantiated once per render via a constant so SwiftUI
/// doesn't reallocate the path on every redraw; hover effect uses opacity
/// (not conditional `.shadow`) so the layer doesn't get destroyed and rebuilt
/// when the cursor enters/leaves.
struct OttoChip: View {
    let text: String
    var action: () -> Void

    @State private var hover = false

    private static let shape = AngledPanelShape(cut: .parallelogram(8))

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Typography.caption)
                .tracking(1.2)
                .foregroundStyle(hover ? Theme.Colors.cyan : Theme.Colors.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Self.shape.fill(Theme.Colors.bg1.opacity(0.85)))
                .overlay(
                    Self.shape.stroke(
                        hover ? Theme.Colors.cyan : Theme.Colors.cyan.opacity(0.3),
                        lineWidth: 1
                    )
                )
                .shadow(color: Theme.Colors.cyanGlow, radius: 10)
                .opacity(hover ? 1 : 0.9)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
