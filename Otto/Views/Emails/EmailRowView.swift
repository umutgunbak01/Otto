import SwiftUI

struct EmailRowView: View {
    @Environment(AppState.self) private var appState
    let email: Email
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            // Unread indicator (mockup .unread-dot / .read-pad) — teal dot
            // with a soft glow; clear 6pt spacer once read.
            Circle()
                .fill(email.isRead ? Color.clear : Theme.Colors.cyan)
                .frame(width: 6, height: 6)
                .shadow(
                    color: email.isRead ? Color.clear : Theme.Colors.cyan.opacity(0.5),
                    radius: 4
                )

            // Gradient initials avatar (mockup .fava) — stable per name.
            OttoAvatar(name: email.displaySender, size: 28)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Sender line
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(email.displaySender)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(email.isRead ? Theme.Colors.textDim : Theme.Colors.text)
                        .lineLimit(1)

                    Spacer()

                    // Date (data → mono)
                    Text(email.formattedDate)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Subject
                Text(email.subject)
                    .font(.system(size: 13, weight: email.isRead ? .regular : .medium))
                    .foregroundStyle(email.isRead ? Theme.Colors.textDim : Theme.Colors.text)
                    .lineLimit(1)

                // Preview
                Text(email.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: Theme.Spacing.sm) {
                    // Draft a reply in the user's voice (email triage, opt-in)
                    if EmailTriageSettings.isEnabled {
                        Button {
                            ReplyDraftService.shared.beginDraft(for: email, appState: appState)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Draft reply")
                    }

                    // Convert type menu
                    ConvertTypeMenuCompact(currentType: .note) { newType in
                        Task { await appState.convertEmail(email, to: newType) }
                    }

                    Button {
                        Task { await appState.deleteEmail(email) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 9)
        .background(
            // Quiet list row (mockup .lrow) — no border; unread rows keep a
            // faint panel wash to lift them off the page.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered
                            ? Theme.Colors.panel
                            : (email.isRead ? Color.clear : Theme.Colors.panel))
                )
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }
}

#Preview {
    VStack(spacing: 6) {
        EmailRowView(
            email: Email(
                gmailId: "1",
                threadId: "t1",
                subject: "Meeting Tomorrow",
                sender: "john@example.com",
                senderName: "John Doe",
                body: "Hi, just wanted to confirm our meeting tomorrow at 2pm.",
                receivedDate: Date(),
                isRead: false,
                snippet: "Hi, just wanted to confirm our meeting tomorrow at 2pm."
            )
        )
        EmailRowView(
            email: Email(
                gmailId: "2",
                threadId: "t2",
                subject: "Project Update",
                sender: "jane@company.com",
                senderName: "Jane Smith",
                body: "The project is progressing well. We've completed the first milestone.",
                receivedDate: Date().addingTimeInterval(-86400),
                isRead: true,
                snippet: "The project is progressing well. We've completed the first milestone."
            ),
            isSelected: true
        )
    }
    .environment(AppState())
    .padding()
    .frame(width: 400)
}
