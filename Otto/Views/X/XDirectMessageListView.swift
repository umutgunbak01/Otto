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
            OttoDivider()

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
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("⌬ X DMS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(conversations.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                if appState.isLoadingX {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            // Search field
            if !appState.xDirectMessages.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    TextField("Search messages...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.borderSubtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { message in
                    conversationRow(message)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(message.conversationId)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ message: XDirectMessage) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Sender avatar
            ZStack {
                Circle()
                    .fill(ContentType.xDm.color.opacity(0.12))
                    .frame(width: 32, height: 32)

                Text(String(message.senderDisplayName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ContentType.xDm.color)
            }

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Sender info and timestamp
                HStack {
                    Text(message.senderDisplayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    Text("@\(message.senderUsername)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(message.formattedDate)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Latest message preview
                Text(message.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(1)

                // Message count badge for conversation
                let messageCount = appState.xDirectMessages.filter { $0.conversationId == message.conversationId }.count
                if messageCount > 1 {
                    Text("\(messageCount) messages")
                        .font(Theme.Typography.small)
                        .foregroundStyle(ContentType.xDm.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ContentType.xDm.color.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Color.clear)
        )
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
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func threadMessageRow(_ message: XDirectMessage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Sender and timestamp
            HStack(spacing: Theme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(ContentType.xDm.color.opacity(0.12))
                        .frame(width: 24, height: 24)

                    Text(String(message.senderDisplayName.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ContentType.xDm.color)
                }

                Text(message.senderDisplayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)

                Text("@\(message.senderUsername)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Spacer()

                Text(message.formattedDate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Message text
            Text(message.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
                .textSelection(.enabled)
                .padding(.leading, 32)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "message")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(searchText.isEmpty ? "No X DMs yet" : "No matching conversations")
                    .font(Theme.Typography.title)
                Text("Connect X in Integrations to import your direct messages.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    XDirectMessageListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
