import SwiftUI

// MARK: - Shared X helpers (avatars + row cards)

/// Rotating tinted avatar palette for the X views (mockup .fava a1–a5).
enum XAvatarPalette {
    static let pairs: [(bg: Color, fg: Color)] = [
        (Theme.Colors.tintViolet, Theme.Colors.violet),
        (Theme.Colors.tintGreen,  Theme.Colors.green),
        (Theme.Colors.selectTint, Theme.Colors.accentText),
        (Theme.Colors.tintAmber,  Theme.Colors.amber),
        (Theme.Colors.tintRed,    Theme.Colors.red)
    ]

    /// Stable color pair for a given seed string (e.g. a username).
    static func pair(for seed: String) -> (bg: Color, fg: Color) {
        let sum = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return pairs[abs(sum) % pairs.count]
    }
}

/// 26pt tinted initials avatar used across X rows.
struct XAvatar: View {
    let seed: String
    let initials: String
    var size: CGFloat = 26

    var body: some View {
        let pair = XAvatarPalette.pair(for: seed)
        ZStack {
            Circle()
                .fill(pair.bg)
                .frame(width: size, height: size)

            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(pair.fg)
        }
    }
}

/// Avatar that loads the real X profile image, falling back to the tinted
/// initials circle while loading or when the account has no image URL.
struct XProfileImage: View {
    let urlString: String?
    let seed: String
    let initials: String
    var size: CGFloat = 26

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    XAvatar(seed: seed, initials: initials, size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            XAvatar(seed: seed, initials: initials, size: size)
        }
    }
}

/// Quiet list row (mockup .lrow): no border or card fill — just a rounded
/// wash on hover and a teal tint when selected.
struct XRowCard: ViewModifier {
    var isSelected: Bool = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(
                        isSelected
                            ? Theme.Colors.selectTint
                            : (isHovered ? Theme.Colors.panel : Color.clear)
                    )
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func xRowCard(isSelected: Bool = false) -> some View {
        modifier(XRowCard(isSelected: isSelected))
    }
}

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
        HStack(alignment: .center, spacing: 10) {
            Text("Posts")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(filteredPosts.count)")

            if appState.isLoadingX {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Spacer(minLength: 8)

            if !appState.xPosts.isEmpty {
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
                    OttoBarButtonLabel(label: "Sort: \(sortOption.rawValue)", showsCaret: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort posts")

                OttoSearchMini(placeholder: "Search posts…", text: $searchText, width: 200)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Post List

    private var postList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredPosts) { post in
                    postRow(post)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(post.id)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Post Row

    private func postRow(_ post: XPost) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Author avatar
            XAvatar(
                seed: post.authorUsername,
                initials: String(post.authorDisplayName.prefix(1)).uppercased()
            )
            .padding(.top, 2)

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Author info and date (mockup .xhead)
                HStack(spacing: 7) {
                    Text(post.authorDisplayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    Text("@\(post.authorUsername)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(post.formattedDate)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Post text preview
                Text(post.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineSpacing(3)
                    .lineLimit(3)

                // Engagement stats (mockup .engage)
                HStack(spacing: 18) {
                    engagementStat(icon: "heart", count: post.likeCount)
                    engagementStat(icon: "arrow.2.squarepath", count: post.retweetCount)
                    engagementStat(icon: "bubble.right", count: post.replyCount)
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 11)
        .xRowCard()
    }

    private func engagementStat(icon: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(OttoFormatters.compactCount(count))
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Theme.Colors.tertiaryText)
    }

    // MARK: - Post Detail View

    private func xPostDetailView(_ post: XPost) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Author header
                HStack(spacing: Theme.Spacing.md) {
                    XAvatar(
                        seed: post.authorUsername,
                        initials: String(post.authorDisplayName.prefix(1)).uppercased(),
                        size: 48
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorDisplayName)
                            .font(Theme.Typography.title)

                        Text("@\(post.authorUsername)")
                            .font(Theme.Typography.monoBody)
                            .foregroundStyle(Theme.Colors.tertiaryText)
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
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                OttoDivider()

                // Engagement stats
                HStack(spacing: Theme.Spacing.xl) {
                    VStack(spacing: Theme.Spacing.xs) {
                        Text("\(post.likeCount)")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
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
                            AngularChip(fill: Theme.Colors.selectTint) {
                                Text("Repost")
                                    .font(Theme.Typography.monoSmall)
                                    .foregroundStyle(Theme.Colors.accentText)
                            }
                        }
                        if post.isReply {
                            AngularChip(fill: Theme.Colors.selectTint) {
                                Text("Reply")
                                    .font(Theme.Typography.monoSmall)
                                    .foregroundStyle(Theme.Colors.accentText)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "text.bubble",
            title: searchText.isEmpty ? "No posts yet" : "No matching posts",
            message: "Connect X in Integrations to index your posts."
        )
    }
}

#Preview {
    XPostListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
