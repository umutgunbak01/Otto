import SwiftUI

/// Floating "data node" — small rounded card with a tiny label, a big
/// number, and an optional sub-line. (Legacy HUD component; kept compiling
/// for any remaining call sites.)
struct OttoDataNode: View {
    enum Tone { case cyan, amber, green, red }

    let label: String
    let value: String
    let sub: String?
    var tone: Tone = .cyan

    private var color: Color {
        switch tone {
        case .cyan:  return Theme.Colors.accent
        case .amber: return Theme.Colors.amber
        case .green: return Theme.Colors.green
        case .red:   return Theme.Colors.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Typography.label)
                .tracking(Theme.Tracking.xwide)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            if let sub = sub {
                Text(sub)
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 160, alignment: .leading)
        .angledPanel(.topRightBottomLeft(8))
    }
}

/// Suggestion chip — rounded pill with a hairline border; the border
/// brightens on hover (mockup hover rule: no glows, just border).
struct OttoChip: View {
    let text: String
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(hover ? Theme.Colors.text : Theme.Colors.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(
                            hover ? Theme.Colors.borderStrong : Theme.Colors.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
