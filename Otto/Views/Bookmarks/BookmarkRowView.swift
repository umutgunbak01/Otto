import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct BookmarkRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    let bookmark: Bookmark
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Thumbnail or favicon
            thumbnailView

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Title
                Text(bookmark.title)
                    .font(Theme.Typography.headline)
                    .strikethrough(bookmark.isRead, color: Theme.Colors.secondaryText)
                    .foregroundStyle(bookmark.isRead ? Theme.Colors.secondaryText : Theme.Colors.text)
                    .lineLimit(1)

                // Description from OG or user-entered
                if let desc = displayDescription, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                }

                // URL domain + site name + badges
                HStack(spacing: Theme.Spacing.sm) {
                    // Favicon + domain
                    HStack(spacing: 4) {
                        if let faviconUrl = bookmark.faviconUrl, let url = URL(string: faviconUrl) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 12, height: 12)
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                default:
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                            }
                        } else {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }

                        Text(bookmark.siteName ?? urlHost ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }

                    // Media type badge
                    Text(bookmark.mediaType.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(mediaTypeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(mediaTypeColor.opacity(0.1))
                        .clipShape(Capsule())

                    // Category
                    Text(bookmark.primaryCategory.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(categoryColor)
                }
            }

            Spacer()

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: Theme.Spacing.sm) {
                    // Open in browser
                    Button {
                        if let url = URL(string: bookmark.url) {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)

                    // Toggle read status
                    Button {
                        Task { await appState.toggleBookmarkRead(bookmark) }
                    } label: {
                        Image(systemName: bookmark.isRead ? "circle" : "checkmark.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Colors.personal)
                    }
                    .buttonStyle(.plain)

                    // Convert type menu
                    ConvertTypeMenuCompact(currentType: .bookmark) { newType in
                        Task { await appState.convertBookmark(bookmark, to: newType) }
                    }

                    // Delete
                    Button {
                        Task { await appState.deleteBookmark(bookmark) }
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

    // MARK: - Thumbnail

    private var thumbnailView: some View {
        Group {
            if let ogImageUrl = bookmark.ogImageUrl, let url = URL(string: ogImageUrl) {
                // OG image thumbnail
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    case .failure:
                        fallbackIcon
                    default:
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.hoverTint)
                            .frame(width: 72, height: 52)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.5)
                            )
                    }
                }
            } else {
                fallbackIcon
            }
        }
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(mediaTypeColor.opacity(0.08))
                .frame(width: 72, height: 52)

            VStack(spacing: 2) {
                Image(systemName: bookmark.mediaType.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(mediaTypeColor)

                if let host = urlHost {
                    Text(host.prefix(12))
                        .font(.system(size: 8))
                        .foregroundStyle(mediaTypeColor.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Helpers

    private var displayDescription: String? {
        // Prefer OG description, fall back to user description
        if let ogDesc = bookmark.ogDescription, !ogDesc.isEmpty {
            return ogDesc
        }
        if !bookmark.description.isEmpty {
            return bookmark.description
        }
        return nil
    }

    private var urlHost: String? {
        guard let url = URL(string: bookmark.url),
              let host = url.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private var mediaTypeColor: Color {
        switch bookmark.mediaType {
        case .readLater: return Theme.Colors.work
        case .listenLater: return Theme.Colors.hobby
        case .watchLater: return Theme.Colors.priorityHigh
        }
    }

    private var categoryColor: Color {
        switch bookmark.primaryCategory {
        case .work: return Theme.Colors.work
        case .personal: return Theme.Colors.personal
        case .hobby: return Theme.Colors.hobby
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        BookmarkRowView(bookmark: Bookmark(
            title: "SwiftUI Documentation",
            url: "https://developer.apple.com/documentation/swiftui",
            mediaType: .readLater,
            primaryCategory: .work,
            ogImageUrl: "https://developer.apple.com/news/images/og/swiftui-og.png",
            ogDescription: "SwiftUI helps you build great-looking apps across all Apple platforms.",
            siteName: "Apple Developer"
        ))
        BookmarkRowView(bookmark: Bookmark(
            title: "WWDC 2024 Keynote",
            url: "https://www.youtube.com/watch?v=example",
            mediaType: .watchLater,
            primaryCategory: .personal,
            ogDescription: "Watch the latest announcements from Apple's Worldwide Developer Conference."
        ))
        BookmarkRowView(bookmark: Bookmark(
            title: "The Swift Programming Podcast",
            url: "https://podcasts.apple.com/podcast/swift",
            mediaType: .listenLater,
            primaryCategory: .hobby,
            isRead: true
        ))
    }
    .environment(AppState())
    .padding()
    .frame(width: 500)
}
