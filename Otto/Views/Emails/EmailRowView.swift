import SwiftUI

struct EmailRowView: View {
    @Environment(AppState.self) private var appState
    let email: Email
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Email icon with read status
            ZStack {
                Circle()
                    .fill(email.isRead ? Theme.Colors.borderSubtle : Theme.Colors.accent.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(systemName: email.isRead ? "envelope.open" : "envelope.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(email.isRead ? Theme.Colors.tertiaryText : Theme.Colors.accent)
            }

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Sender
                HStack {
                    Text(email.displaySender)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(email.isRead ? Theme.Colors.secondaryText : Theme.Colors.text)
                        .lineLimit(1)

                    Spacer()

                    // Date
                    Text(email.formattedDate)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Subject
                Text(email.subject)
                    .font(Theme.Typography.body)
                    .foregroundStyle(email.isRead ? Theme.Colors.secondaryText : Theme.Colors.text)
                    .lineLimit(1)

                // Preview
                Text(email.preview)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(2)
            }

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: Theme.Spacing.sm) {
                    // Convert type menu
                    ConvertTypeMenuCompact(currentType: .note) { newType in
                        Task { await appState.convertEmail(email, to: newType) }
                    }

                    Button {
                        Task { await appState.deleteEmail(email) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.08) : (isHovered ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isSelected ? Theme.Colors.accent.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }
}

#Preview {
    VStack(spacing: 2) {
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
