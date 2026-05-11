import SwiftUI

struct XPostListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .date
    @State private var navigationPath = NavigationPath()

    enum SortOption: String, CaseIterable {
        case date = "Date"
        case likes = "Likes"
        case engagement = "Engagement"

        var description: String {
            switch self {
            case .date: return "Sort by date (newest first)"
            case .likes: return "Sort by like count"
            case .engagement: return "Sort by total engagement"
            }
        }
    }

    var filteredPosts: [XPost] {
        var result = appState.xPosts

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { post in
                post.text.localizedCaseInsensitiveContains(searchText) ||
                post.authorUsername.localizedCaseInsensitiveContains(searchText) ||
                post.authorDisplayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOption {
        case .date:
            result.sort { $0.createdAt > $1.createdAt }
        case .likes:
            result.sort { $0.likeCount > $1.likeCount }
        case .engagement:
            result.sort { $0.engagementTotal > $1.engagementTotal }
        }

        return result
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listPanel
                .navigationDestination(for: UUID.self) { postId in
                    if let post = appState.xPosts.first(where: { $0.id == postId }) {
                        xPostDetailView(post)
                    }
                }
        }
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.xPosts.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.xPosts.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()

            if filteredPosts.isEmpty {
                emptyState
            } else {
                postList
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
                Text("⌬ X POSTS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filteredPosts.count)")
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
            if !appState.xPosts.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        TextField("Search posts...", text: $searchText)
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

                    // Sort picker
                    HStack(spacing: Theme.Spacing.sm) {
                        Menu {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Button {
                                    sortOption = option
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        if sortOption == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 9))
                                Text(sortOption.rawValue)
                                    .font(Theme.Typography.caption)
                            }
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.borderSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        }
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        #endif

                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Post List

    private var postList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredPosts) { post in
                    postRow(post)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(post.id)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Post Row

    private func postRow(_ post: XPost) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Author avatar
            ZStack {
                Circle()
                    .fill(ContentType.xPost.color.opacity(0.12))
                    .frame(width: 32, height: 32)

                Text(String(post.authorDisplayName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ContentType.xPost.color)
            }

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Author info and date
                HStack {
                    Text(post.authorDisplayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    Text("@\(post.authorUsername)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(post.formattedDate)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Post text preview
                Text(post.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(2)

                // Engagement stats
                HStack(spacing: Theme.Spacing.lg) {
                    engagementStat(icon: "heart", count: post.likeCount)
                    engagementStat(icon: "arrow.2.squarepath", count: post.retweetCount)
                    engagementStat(icon: "bubble.right", count: post.replyCount)
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Color.clear)
        )
    }

    private func engagementStat(icon: String, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text("\(count)")
                .font(Theme.Typography.caption)
        }
        .foregroundStyle(Theme.Colors.tertiaryText)
    }

    // MARK: - Post Detail View

    private func xPostDetailView(_ post: XPost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Author header
                HStack(spacing: Theme.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(ContentType.xPost.color.opacity(0.12))
                            .frame(width: 48, height: 48)

                        Text(String(post.authorDisplayName.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ContentType.xPost.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorDisplayName)
                            .font(Theme.Typography.title)

                        Text("@\(post.authorUsername)")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Spacer()
                }

                // Full post text
                Text(post.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                    .textSelection(.enabled)

                // Date
                Text(post.formattedDate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                OttoDivider()

                // Engagement stats
                HStack(spacing: Theme.Spacing.xl) {
                    VStack(spacing: Theme.Spacing.xs) {
                        Text("\(post.likeCount)")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.text)
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "heart")
                                .font(.system(size: 12))
                            Text("Likes")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    VStack(spacing: Theme.Spacing.xs) {
                        Text("\(post.retweetCount)")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.text)
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.system(size: 12))
                            Text("Reposts")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    VStack(spacing: Theme.Spacing.xs) {
                        Text("\(post.replyCount)")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.text)
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 12))
                            Text("Replies")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                // Badges
                if post.isRetweet || post.isReply {
                    HStack(spacing: Theme.Spacing.sm) {
                        if post.isRetweet {
                            Text("Repost")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.xPost.color)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(ContentType.xPost.color.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        if post.isReply {
                            Text("Reply")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.xPost.color)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(ContentType.xPost.color.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "text.bubble")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(searchText.isEmpty ? "No X posts yet" : "No matching posts")
                    .font(Theme.Typography.title)
                Text("Connect X in Integrations to import your tweets.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    XPostListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
