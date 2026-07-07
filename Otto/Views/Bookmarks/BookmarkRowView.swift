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
                    .font(.system(size: 13.5, weight: bookmark.isRead ? .regular : .medium))
                    .strikethrough(bookmark.isRead, color: Theme.Colors.textDim)
                    .foregroundStyle(bookmark.isRead ? Theme.Colors.textDim : Theme.Colors.text)
                    .lineLimit(1)

                // Description from OG or user-entered
                if let desc = displayDescription, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textDim)
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
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }

                    // Media type badge — fixedSize so a tight row truncates
                    // the domain text instead of letter-wrapping the chips.
                    Text(bookmark.mediaType.rawValue)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(mediaTypeColor)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(mediaTypeTint)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Category
                    Text(bookmark.primaryCategory.rawValue)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(categoryColor)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            Spacer()

            // Relative date (hidden while hover actions are shown)
            if !isHovered {
                Text(relativeDate(bookmark.createdAt))
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

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
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.selectTint : Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(
                    isSelected || isHovered ? Theme.Colors.borderStrong : Theme.Colors.border,
                    lineWidth: 1
                )
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
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            )
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
                .fill(Theme.Colors.hoverTint)
                .frame(width: 72, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )

            VStack(spacing: 2) {
                Image(systemName: bookmark.mediaType.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if let host = urlHost {
                    Text(host.prefix(12))
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
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
        case .readLater: return Theme.Colors.accentText
        case .listenLater: return Theme.Colors.violet
        case .watchLater: return Theme.Colors.amber
        }
    }

    private var mediaTypeTint: Color {
        switch bookmark.mediaType {
        case .readLater: return Theme.Colors.selectTint
        case .listenLater: return Theme.Colors.tintViolet
        case .watchLater: return Theme.Colors.tintAmber
        }
    }

    private var categoryColor: Color {
        switch bookmark.primaryCategory {
        case .work: return Theme.Colors.accentText
        case .personal: return Theme.Colors.green
        case .hobby: return Theme.Colors.violet
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        else if interval < 3600 { return "\(Int(interval / 60))m" }
        else if interval < 86400 { return "\(Int(interval / 3600))h" }
        else if interval < 604800 { return "\(Int(interval / 86400))d" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
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
