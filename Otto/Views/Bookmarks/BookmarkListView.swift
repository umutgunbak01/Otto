import SwiftUI

struct BookmarkListView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: BookmarkFilter = .all
    @State private var mediaFilter: Bookmark.MediaType?
    @State private var selectedBookmarkId: UUID?

    enum BookmarkFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case read = "Read"

        var id: String { rawValue }
    }

    var filteredBookmarks: [Bookmark] {
        var result = appState.bookmarks.sorted { $0.createdAt > $1.createdAt }

        // Apply read status filter
        switch filter {
        case .all:
            break
        case .unread:
            result = result.filter { !$0.isRead }
        case .read:
            result = result.filter { $0.isRead }
        }

        // Apply media type filter
        if let mediaType = mediaFilter {
            result = result.filter { $0.mediaType == mediaType }
        }

        return result
    }

    private var showDetailPanel: Bool {
        selectedBookmarkId != nil && appState.bookmarks.contains(where: { $0.id == selectedBookmarkId })
    }

    var body: some View {
        HStack(spacing: 0) {
            // List Panel - expands when detail is hidden
            listPanel
                .frame(minWidth: 320, maxWidth: showDetailPanel ? 400 : .infinity)

            if showDetailPanel {
                OttoDivider()

                // Detail Panel - collapsible
                detailPanel
                    .frame(minWidth: 350, maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDetailPanel)
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.bookmarks.contains(where: { $0.id == itemId }) {
                selectedBookmarkId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.bookmarks.contains(where: { $0.id == itemId }) {
                selectedBookmarkId = itemId
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let bookmarkId = selectedBookmarkId,
               let bookmark = appState.bookmarks.first(where: { $0.id == bookmarkId }) {
                BookmarkDetailView(
                    bookmark: bookmark,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedBookmarkId = nil
                        }
                    }
                )
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header
            header

            OttoDivider()

            // Content
            if filteredBookmarks.isEmpty {
                emptyState
            } else {
                bookmarkList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("⌬ BOOKMARKS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filteredBookmarks.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                // Status filter picker
                BookmarkFilterPicker(selection: $filter)
            }

            // Media type filter
            HStack(spacing: Theme.Spacing.sm) {
                mediaTypeButton(nil, label: "All")
                mediaTypeButton(.readLater, label: "Read Later")
                mediaTypeButton(.listenLater, label: "Listen Later")
                mediaTypeButton(.watchLater, label: "Watch Later")
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    private func mediaTypeButton(_ type: Bookmark.MediaType?, label: String) -> some View {
        let isActive = mediaFilter == type

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                mediaFilter = type
            }
        } label: {
            HStack(spacing: 4) {
                if let mediaType = type {
                    Image(systemName: mediaType.iconName)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isActive ? Theme.Colors.accent.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isActive ? Theme.Colors.accent.opacity(0.3) : Theme.Colors.border, lineWidth: 1)
            )
            .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bookmark List

    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredBookmarks) { bookmark in
                    BookmarkRowView(bookmark: bookmark, isSelected: selectedBookmarkId == bookmark.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if selectedBookmarkId == bookmark.id {
                                    selectedBookmarkId = nil // Toggle off if already selected
                                } else {
                                    selectedBookmarkId = bookmark.id
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "bookmark")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(emptyStateTitle)
                    .font(Theme.Typography.title)
                Text("Paste a URL to save it for later")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if let mediaType = mediaFilter {
            return "No \(mediaType.rawValue.lowercased()) items"
        }
        switch filter {
        case .all: return "No bookmarks yet"
        case .unread: return "No unread bookmarks"
        case .read: return "No read bookmarks"
        }
    }
}

#Preview {
    BookmarkListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
