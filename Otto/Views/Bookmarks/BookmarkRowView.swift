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
                // Title — read state is signalled by the row-level dim, so
                // the title keeps full-strength text plus the strikethrough.
                Text(bookmark.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(bookmark.isRead, color: Theme.Colors.textDim)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                // Description from OG or user-entered
                if let desc = displayDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Colors.tertiaryText)
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
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }

                    // Media type chip — fixedSize so a tight row truncates
                    // the domain text instead of letter-wrapping the chips.
                    metaChip(bookmark.mediaType.rawValue.lowercased(), color: mediaTypeColor)

                    if bookmark.isRead {
                        metaChip("read", color: Theme.Colors.green)
                    }

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
                    .font(.system(size: 10, design: .monospaced))
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
        // Read rows dim wholesale (mockup .lrow.dim); the wash below stays
        // full strength so selection is still readable.
        .opacity(bookmark.isRead ? 0.55 : 1)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 10)
        .background(
            // Quiet list row (mockup .lrow) — no border, wash on hover,
            // teal tint when selected.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered ? Theme.Colors.panel : Color.clear)
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
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                // Inset hairline, not a border — keeps the
                                // thumbnail edge crisp on the quiet row.
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                            )
                    case .failure:
                        fallbackIcon
                    default:
                        RoundedRectangle(cornerRadius: 9)
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
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.Colors.hoverTint)
                .frame(width: 72, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )

            VStack(spacing: 2) {
                // Tinted per media type — the no-image case is where the
                // mockup's colored icon square shows through.
                Image(systemName: bookmark.mediaType.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(mediaTypeColor)

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

    /// Small colored status capsule (mockup .chip2) — mono label on a 10%
    /// wash with a 20% stroke of the same color.
    private func metaChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1))
    }

    private var mediaTypeColor: Color {
        switch bookmark.mediaType {
        case .readLater: return Theme.Colors.textDim
        case .listenLater: return Theme.Colors.violet
        case .watchLater: return Theme.Colors.red
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
