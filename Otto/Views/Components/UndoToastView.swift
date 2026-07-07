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
                .foregroundStyle(Theme.Colors.textDim)

            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.text)

            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 1, height: 14)

            Button {
                onUndo()
            } label: {
                Text("Undo")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)
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
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.Colors.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isVisible = true
            }
        }
    }
}
