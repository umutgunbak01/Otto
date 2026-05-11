import SwiftUI

struct UndoToastView: View {
    let label: String
    var onUndo: () -> Void
    var onDismiss: () -> Void

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.cyan.opacity(0.7))

            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Theme.Colors.text)

            Rectangle()
                .fill(Theme.Colors.cyan.opacity(0.25))
                .frame(width: 1, height: 14)

            Button {
                onUndo()
            } label: {
                Text("UNDO")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            AngledPanelShape(cut: .topRightBottomLeft(8))
                .fill(Theme.Colors.bg1.opacity(0.95))
        )
        .overlay(
            AngledPanelShape(cut: .topRightBottomLeft(8))
                .stroke(Theme.Colors.cyan, lineWidth: 1)
        )
        .shadow(color: Theme.Colors.cyanGlow.opacity(0.4), radius: 12)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isVisible = true
            }
        }
    }
}
