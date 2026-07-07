import SwiftUI

struct EmailRowView: View {
    @Environment(AppState.self) private var appState
    let email: Email
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            // Unread indicator (mockup .unread-dot / .read-pad)
            Circle()
                .fill(email.isRead ? Color.clear : Theme.Colors.accent)
                .frame(width: 7, height: 7)

            // Tinted initials avatar (mockup .fava)
            senderAvatar

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Sender line
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(email.displaySender)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(email.isRead ? Theme.Colors.textDim : Theme.Colors.text)
                        .lineLimit(1)

                    Spacer()

                    // Date (data → mono)
                    Text(email.formattedDate)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Subject
                Text(email.subject)
                    .font(email.isRead
                          ? Font.system(size: 13, weight: .regular)
                          : Font.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(email.isRead ? Theme.Colors.textDim : Theme.Colors.text)
                    .lineLimit(1)

                // Preview
                Text(email.preview)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (email.isRead ? Color.clear : Theme.Colors.panel)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    // MARK: - Avatar

    private var senderAvatar: some View {
        let initials = avatarInitials
        let tint = avatarTint(for: email.sender)

        return Circle()
            .fill(tint.background)
            .frame(width: 26, height: 26)
            .overlay {
                Text(initials)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.foreground)
            }
    }

    private var avatarInitials: String {
        let name = email.senderName ?? email.sender
        let parts = name.split(separator: " ").prefix(2)
        if parts.count >= 2 {
            return parts.map { String($0.prefix(1)) }.joined().uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func avatarTint(for sender: String) -> (background: Color, foreground: Color) {
        let tints: [(Color, Color)] = [
            (Theme.Colors.tintViolet, Theme.Colors.violet),
            (Theme.Colors.tintGreen, Theme.Colors.green),
            (Theme.Colors.selectTint, Theme.Colors.accentText),
            (Theme.Colors.tintAmber, Theme.Colors.amber),
            (Theme.Colors.tintRed, Theme.Colors.red)
        ]
        var hash = 0
        for scalar in sender.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        return tints[hash % tints.count]
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
