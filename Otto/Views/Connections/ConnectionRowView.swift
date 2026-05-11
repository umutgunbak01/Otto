import SwiftUI

struct ConnectionRowView: View {
    @Environment(AppState.self) private var appState
    let connection: Connection
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Initials avatar
            ZStack {
                Circle()
                    .fill(ContentType.connection.color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Text(connection.initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ContentType.connection.color)
            }

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Name and company
                HStack {
                    Text(connection.fullName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    if connection.closeness != .unknown {
                        Image(systemName: connection.closeness.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(connection.closeness.color)
                    }

                    Spacer()

                    // Connection date if available
                    if let date = connection.connectionDate {
                        Text(formatDate(date))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }

                // Headline @ Company
                if !connection.headline.isEmpty || !connection.company.isEmpty {
                    Text(headlineText)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }

                // Tags
                if !connection.tags.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(connection.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.connection.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(ContentType.connection.color.opacity(0.1))
                                )
                        }
                        if connection.tags.count > 3 {
                            Text("+\(connection.tags.count - 3)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                }
            }

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: Theme.Spacing.sm) {
                    // Open LinkedIn
                    if let url = connection.profileUrl, let linkedInURL = URL(string: url) {
                        Button {
                            openURL(linkedInURL)
                        } label: {
                            Image(systemName: "link")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .help("Open LinkedIn Profile")
                        #endif
                    }

                    // Delete
                    Button {
                        Task { await appState.deleteConnection(connection) }
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

    private var headlineText: String {
        if !connection.headline.isEmpty && !connection.company.isEmpty {
            return "\(connection.headline) @ \(connection.company)"
        } else if !connection.headline.isEmpty {
            return connection.headline
        } else {
            return connection.company
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

#Preview {
    VStack(spacing: 2) {
        ConnectionRowView(
            connection: Connection(
                firstName: "John",
                lastName: "Doe",
                headline: "Software Engineer",
                company: "Google",
                location: "San Francisco, CA",
                email: "john.doe@gmail.com",
                profileUrl: "https://linkedin.com/in/johndoe",
                connectionDate: Date(),
                notes: "",
                tags: ["engineering", "tech"]
            )
        )
        ConnectionRowView(
            connection: Connection(
                firstName: "Jane",
                lastName: "Smith",
                headline: "Product Manager",
                company: "Apple",
                location: "Cupertino, CA",
                email: nil,
                profileUrl: nil,
                connectionDate: Date().addingTimeInterval(-86400 * 30),
                notes: "Met at conference",
                tags: ["product", "tech", "investor", "advisor"]
            ),
            isSelected: true
        )
    }
    .environment(AppState())
    .padding()
    .frame(width: 400)
}
