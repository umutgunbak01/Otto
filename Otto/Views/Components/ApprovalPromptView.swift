import SwiftUI

/// Inline approval card rendered in the chat when the Hermes agent calls
/// `session/request_permission`. Four buttons: allow once / allow always /
/// deny once / deny always. The two "always" variants also write to
/// `ToolApprovalPolicy` so future runs auto-resolve.
///
/// After the user clicks, `resolved` flips to true and the buttons fade out
/// to show the decision was registered. Tapping outside the card does not
/// dismiss it — the only way to resolve is via one of the four buttons.
struct ApprovalPromptView: View {
    let toolName: String
    let argsSummary: String
    let resolved: Bool
    let onDecision: (ApprovalDecision, Bool) -> Void  // (decision, isAllow)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.amber)
                Text("PERMISSION REQUEST")
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.wide)
                    .foregroundStyle(Theme.Colors.amber)
            }

            Text(argsSummary)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
                .fixedSize(horizontal: false, vertical: true)

            if !resolved {
                HStack(spacing: Theme.Spacing.sm) {
                    decisionButton(label: "Allow", filled: true) {
                        onDecision(.askEachTime, true)
                    }
                    decisionButton(label: "Allow always", filled: false) {
                        onDecision(.alwaysAllow, true)
                    }
                    Spacer(minLength: 0)
                    decisionButton(label: "Deny", filled: false) {
                        onDecision(.askEachTime, false)
                    }
                    decisionButton(label: "Deny always", filled: false) {
                        onDecision(.alwaysDeny, false)
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textDim)
                    Text("Decision sent")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.Colors.amber.opacity(0.45), lineWidth: 1)
        )
        .opacity(resolved ? 0.55 : 1.0)
        .animation(.easeOut(duration: 0.15), value: resolved)
    }

    @ViewBuilder
    private func decisionButton(label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(filled ? Theme.Colors.cyan.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(
                            filled ? Theme.Colors.cyan : Theme.Colors.border,
                            lineWidth: 1
                        )
                )
                .foregroundStyle(filled ? Theme.Colors.cyan : Theme.Colors.text)
        }
        .buttonStyle(.plain)
    }
}
