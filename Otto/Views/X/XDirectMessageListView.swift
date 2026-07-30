import SwiftUI

struct XDirectMessageListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var navigationPath = NavigationPath()

    /// Groups DMs by conversationId and returns the latest message per conversation, sorted by date.
    var conversations: [XDirectMessage] {
        let allMessages = appState.xDirectMessages

        // Group by conversationId
        let grouped = Dictionary(grouping: allMessages) { $0.conversationId }

        // Get the latest message per conversation
        var latest: [XDirectMessage] = grouped.compactMap { (_, messages) in
            messages.sorted { $0.createdAt > $1.createdAt }.first
        }

        // Filter by search text
        if !searchText.isEmpty {
            latest = latest.filter { message in
                message.senderUsername.localizedCaseInsensitiveContains(searchText) ||
                message.senderDisplayName.localizedCaseInsensitiveContains(searchText) ||
                message.text.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort by most recent first
        latest.sort { $0.createdAt > $1.createdAt }

        return latest
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listPanel
                .navigationDestination(for: String.self) { conversationId in
                    conversationThreadView(conversationId: conversationId)
                }
        }
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               let message = appState.xDirectMessages.first(where: { $0.id == itemId }) {
                navigationPath.append(message.conversationId)
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               let message = appState.xDirectMessages.first(where: { $0.id == itemId }) {
                navigationPath.append(message.conversationId)
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            header

            if conversations.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("DMs")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: conversationCountText)

            if appState.isLoadingX {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Spacer(minLength: 8)

            // Search field
            if !appState.xDirectMessages.isEmpty {
                OttoSearchMini(placeholder: "Search messages…", text: $searchText, width: 200)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var conversationCountText: String {
        let count = conversations.count
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(conversations) { message in
                    conversationRow(message)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(message.conversationId)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ message: XDirectMessage) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Sender avatar
            XAvatar(
                seed: message.senderUsername,
                initials: String(message.senderDisplayName.prefix(1)).uppercased(),
                size: 30
            )
            .padding(.top, 1)

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Sender info and timestamp (mockup .xhead)
                HStack(spacing: 7) {
                    Text(message.senderDisplayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    Text("@\(message.senderUsername)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(message.formattedDate)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Latest message preview
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineSpacing(3)
                    .lineLimit(1)

                // Message count for the conversation
                let messageCount = appState.xDirectMessages.filter { $0.conversationId == message.conversationId }.count
                if messageCount > 1 {
                    Text("\(messageCount) messages")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 10)
        .xRowCard()
    }

    // MARK: - Conversation Thread View

    private func conversationThreadView(conversationId: String) -> some View {
        let messages = appState.xDirectMessages
            .filter { $0.conversationId == conversationId }
            .sorted { $0.createdAt < $1.createdAt }

        let participantName = messages.first?.senderDisplayName ?? "Conversation"

        return VStack(spacing: 0) {
            // Thread header
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(ContentType.xDm.color.opacity(0.12))
                        .frame(width: 36, height: 36)

                    Image(systemName: "message.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(ContentType.xDm.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(participantName)
                        .font(Theme.Typography.headline)

                    Text("\(messages.count) messages")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)

            OttoDivider()

            // Messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(messages) { message in
                        threadMessageRow(message)
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 828)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func threadMessageRow(_ message: XDirectMessage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Sender and timestamp (mockup .xhead)
            HStack(spacing: Theme.Spacing.sm) {
                XAvatar(
                    seed: message.senderUsername,
                    initials: String(message.senderDisplayName.prefix(1)).uppercased(),
                    size: 24
                )

                Text(message.senderDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)

                Text("@\(message.senderUsername)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Spacer()

                Text(message.formattedDate)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Message text
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.leading, 32)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "message",
            title: searchText.isEmpty ? "No DMs yet" : "No matching conversations",
            message: "Connect X in Integrations to import your direct messages."
        )
    }
}

#Preview {
    XDirectMessageListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
