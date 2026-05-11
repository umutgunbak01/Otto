import SwiftUI

struct GmailSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var newBlockedEmail: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Gmail Settings")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.xl)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Connection Status
                    connectionSection

                    Divider()

                    // Blocked Senders
                    blockedSendersSection
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .frame(width: 500, height: 500)
        .background(Theme.Colors.background)
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Connection")
                .font(Theme.Typography.headline)

            HStack {
                ZStack {
                    Circle()
                        .fill(appState.isGmailConnected ? Theme.Colors.personal.opacity(0.12) : Color.primary.opacity(0.05))
                        .frame(width: 40, height: 40)

                    Image(systemName: appState.isGmailConnected ? "checkmark" : "envelope")
                        .font(.system(size: 16))
                        .foregroundStyle(appState.isGmailConnected ? Theme.Colors.personal : Theme.Colors.tertiaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.isGmailConnected ? "Connected" : "Not Connected")
                        .font(Theme.Typography.body)

                    if let lastSync = appState.lastGmailSync {
                        Text("Last synced: \(formatDate(lastSync))")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                Spacer()

                if appState.isGmailConnected {
                    Button {
                        Task { await appState.disconnectGmail() }
                    } label: {
                        Text("Disconnect")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.priorityUrgent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await appState.connectGmail() }
                    } label: {
                        Text("Connect")
                            .font(Theme.Typography.body)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Theme.Colors.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - Blocked Senders Section

    private var blockedSendersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Blocked Senders")
                    .font(Theme.Typography.headline)

                Text("Emails from blocked senders won't be imported during sync")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Add new blocked sender
            HStack(spacing: Theme.Spacing.sm) {
                TextField("Enter email address to block...", text: $newBlockedEmail)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.sm)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .onSubmit {
                        addBlockedSender()
                    }

                Button {
                    addBlockedSender()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(newBlockedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // List of blocked senders
            if appState.blockedSenders.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        Text("No blocked senders")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .padding(Theme.Spacing.xl)
                    Spacer()
                }
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            } else {
                VStack(spacing: 2) {
                    ForEach(appState.blockedSenders, id: \.self) { email in
                        blockedSenderRow(email: email)
                    }
                }
                .background(Color.primary.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
    }

    private func blockedSenderRow(email: String) -> some View {
        HStack {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.priorityUrgent.opacity(0.6))

            Text(email)
                .font(Theme.Typography.body)

            Spacer()

            Button {
                Task { await appState.removeBlockedSender(email) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
    }

    // MARK: - Helpers

    private func addBlockedSender() {
        let email = newBlockedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }

        Task {
            await appState.addBlockedSender(email)
            newBlockedEmail = ""
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    GmailSettingsView()
        .environment(AppState())
}
