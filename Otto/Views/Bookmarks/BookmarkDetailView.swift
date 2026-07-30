import SwiftUI

struct BookmarkDetailView: View {
    @Environment(AppState.self) private var appState
    let bookmark: Bookmark
    var onClose: (() -> Void)? = nil

    @State private var title: String = ""
    @State private var url: String = ""
    @State private var description: String = ""
    @State private var mediaType: Bookmark.MediaType = .readLater
    @State private var primaryCategory: PrimaryCategory = .personal

    // Get the current bookmark from appState for live updates
    private var currentBookmark: Bookmark {
        appState.bookmarks.first { $0.id == bookmark.id } ?? bookmark
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.md)

            OttoDivider()

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Title
                    TextField("Untitled", text: $title)
                        .font(Theme.Typography.largeTitle)
                        .kerning(-0.4)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.Colors.text)

                    // Meta section
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        // URL
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "link")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text("URL")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }

                            HStack {
                                TextField("https://...", text: $url)
                                    .font(Theme.Typography.monoBody)
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(Theme.Colors.accentText)

                                if !url.isEmpty, let urlObj = URL(string: url) {
                                    Button {
                                        openURL(urlObj)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.Colors.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Media Type
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: currentBookmark.mediaType.iconName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text("Type")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }

                            BookmarkMediaTypePicker(selection: $mediaType)
                        }

                        // Category
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text("Category")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }

                            CategorySelector(selection: $primaryCategory)
                        }

                        // Tags
                        if !bookmark.domainTagIds.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Image(systemName: "tag")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                    Text("Tags")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                }

                                FlowLayout(spacing: Theme.Spacing.sm) {
                                    ForEach(appState.tags(for: bookmark.domainTagIds)) { tag in
                                        TagChipView(tag: tag)
                                    }
                                }
                            }
                        }

                        // Timestamp
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text("Added \(timeAgo(bookmark.createdAt))")
                                .font(Theme.Typography.monoCaption)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )

                    // Notes/Description
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text("Notes")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }

                        TextEditor(text: $description)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                            .padding(Theme.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.Colors.bgInput)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            )
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        // Detail panes sit on a faint wash above the shared backdrop.
        .background(Theme.Colors.panelWash)
        .onAppear { loadBookmark() }
        .onChange(of: bookmark.id) { loadBookmark() }
        .onChange(of: title) { saveChanges() }
        .onChange(of: url) { saveChanges() }
        .onChange(of: description) { saveChanges() }
        .onChange(of: mediaType) { saveChanges() }
        .onChange(of: primaryCategory) { saveChanges() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Close button
            if onClose != nil {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
            }

            // Breadcrumb — only the bookmark title is flexible; the fixed
            // parts must never letter-wrap in a narrow pane.
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "bookmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Bookmarks")
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
                Text("/")
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
                Text(bookmark.title)
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.Spacing.sm)

            // Read status toggle
            Button {
                Task { await appState.toggleBookmarkRead(currentBookmark) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: currentBookmark.isRead ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                    Text(currentBookmark.isRead ? "Read" : "Mark as Read")
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(currentBookmark.isRead ? Theme.Colors.green : Theme.Colors.textDim)
            }
            .buttonStyle(.plain)

            // Convert type
            ConvertTypeMenu(currentType: .bookmark) { newType in
                Task { await appState.convertBookmark(bookmark, to: newType) }
            }

            // Delete
            Button {
                Task { await appState.deleteBookmark(bookmark) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadBookmark() {
        title = bookmark.title
        url = bookmark.url
        description = bookmark.description
        mediaType = bookmark.mediaType
        primaryCategory = bookmark.primaryCategory
    }

    private func saveChanges() {
        var updated = bookmark
        updated.title = title
        updated.url = url
        updated.description = description
        updated.mediaType = mediaType
        updated.primaryCategory = primaryCategory

        Task { await appState.updateBookmark(updated) }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }
}

#Preview {
    BookmarkDetailView(bookmark: Bookmark(
        title: "SwiftUI Documentation",
        url: "https://developer.apple.com/documentation/swiftui",
        description: "Official Apple documentation for SwiftUI framework.",
        mediaType: .readLater,
        primaryCategory: .work
    ))
    .environment(AppState())
    .frame(width: 600, height: 500)
}
