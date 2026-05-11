import SwiftUI

struct XFollowerDetailView: View {
    @Environment(AppState.self) private var appState
    let followerId: UUID
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil

    @State private var showingConnectionPicker: Bool = false

    /// Always reads the latest follower data from appState
    private var follower: XFollower {
        appState.xFollowers.first(where: { $0.id == followerId }) ?? initialFollower
    }

    private let initialFollower: XFollower

    init(follower: XFollower, isSidebarCollapsed: Bool = false, onToggleSidebar: (() -> Void)? = nil) {
        self.followerId = follower.id
        self.initialFollower = follower
        self.isSidebarCollapsed = isSidebarCollapsed
        self.onToggleSidebar = onToggleSidebar
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            OttoDivider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Profile header
                    profileHeader

                    OttoDivider()

                    // Stats
                    statsSection

                    OttoDivider()

                    // Linked Connection
                    linkedConnectionSection

                    OttoDivider()

                    // Bio section
                    if !follower.bio.isEmpty {
                        bioSection
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .sheet(isPresented: $showingConnectionPicker) {
            connectionPickerSheet
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Sidebar toggle button
            if let onToggleSidebar = onToggleSidebar {
                Button {
                    onToggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14))
                        .foregroundStyle(isSidebarCollapsed ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
            }

            // Breadcrumb
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ContentType.xFollower.color)
                Text("X Followers")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if !follower.displayName.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
                    Text(follower.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            // Avatar
            ZStack {
                Circle()
                    .fill(ContentType.xFollower.color.opacity(0.12))
                    .frame(width: 64, height: 64)

                Text(follower.initials)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ContentType.xFollower.color)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(follower.displayName)
                    .font(Theme.Typography.largeTitle)

                Text("@\(follower.username)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)

                if follower.isMutual {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10))
                        Text("Mutual")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(ContentType.xFollower.color)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(ContentType.xFollower.color.opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            Spacer()
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Stats")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.xs) {
                    Text("\(follower.followersCount)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.text)
                    Text("Followers")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                VStack(spacing: Theme.Spacing.xs) {
                    Text("\(follower.followingCount)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.text)
                    Text("Following")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
    }

    // MARK: - Linked Connection Section

    private var linkedConnectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Linked Connection")
                .font(Theme.Typography.headline)

            if let connection = appState.linkedConnection(for: follower) {
                // Show linked connection
                HStack(spacing: Theme.Spacing.md) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(ContentType.connection.color.opacity(0.12))
                            .frame(width: 40, height: 40)

                        Text(connection.initials)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ContentType.connection.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.fullName)
                            .font(Theme.Typography.headline)

                        if !connection.company.isEmpty {
                            Text(connection.company)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                    }

                    Spacer()

                    Button {
                        Task {
                            await appState.unlinkFollowerFromConnection(followerId: follower.id)
                        }
                    } label: {
                        Text("Unlink")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.priorityUrgent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(ContentType.connection.color.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(ContentType.connection.color.opacity(0.15), lineWidth: 1)
                )
            } else if !appState.connections.isEmpty {
                // Show link button
                Button {
                    showingConnectionPicker = true
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "link")
                            .font(.system(size: 14))
                        Text("Link to Connection")
                            .font(Theme.Typography.body)
                    }
                    .foregroundStyle(ContentType.connection.color)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(ContentType.connection.color.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            } else {
                Text("No connections available to link")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .italic()
            }
        }
    }

    // MARK: - Bio Section

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Bio")
                .font(Theme.Typography.headline)

            Text(follower.bio)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
                .textSelection(.enabled)
        }
    }

    // MARK: - Connection Picker Sheet

    private var connectionPickerSheet: some View {
        ConnectionPickerView(
            connections: appState.connections,
            onSelect: { connectionId in
                Task {
                    await appState.linkFollowerToConnection(followerId: follower.id, connectionId: connectionId)
                }
                showingConnectionPicker = false
            },
            onCancel: {
                showingConnectionPicker = false
            }
        )
    }
}

// MARK: - Connection Picker View

private struct ConnectionPickerView: View {
    let connections: [Connection]
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    @State private var searchText: String = ""

    var filteredConnections: [Connection] {
        if searchText.isEmpty {
            return connections.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
        }
        return connections.filter { connection in
            connection.fullName.localizedCaseInsensitiveContains(searchText) ||
            connection.company.localizedCaseInsensitiveContains(searchText)
        }
        .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Link to Connection")
                    .font(Theme.Typography.headline)

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.lg)

            // Search
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                TextField("Search connections...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.borderSubtle.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .padding(.horizontal, Theme.Spacing.lg)

            OttoDivider()
                .padding(.top, Theme.Spacing.sm)

            // Connection list
            if filteredConnections.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "person.2")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No matching connections")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredConnections) { connection in
                            Button {
                                onSelect(connection.id)
                            } label: {
                                HStack(spacing: Theme.Spacing.md) {
                                    ZStack {
                                        Circle()
                                            .fill(ContentType.connection.color.opacity(0.12))
                                            .frame(width: 30, height: 30)

                                        Text(connection.initials)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(ContentType.connection.color)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(connection.fullName)
                                            .font(Theme.Typography.headline)
                                            .foregroundStyle(Theme.Colors.text)
                                            .lineLimit(1)

                                        if !connection.company.isEmpty {
                                            Text(connection.company)
                                                .font(Theme.Typography.caption)
                                                .foregroundStyle(Theme.Colors.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
        .frame(width: 400, height: 500)
        .background(Theme.Colors.background)
    }
}

#Preview {
    XFollowerDetailView(
        follower: XFollower(
            xUserId: "123",
            username: "johndoe",
            displayName: "John Doe",
            bio: "Software engineer. Building cool stuff.",
            followersCount: 1250,
            followingCount: 340,
            isMutual: true
        )
    )
    .environment(AppState())
    .frame(width: 600, height: 800)
}
