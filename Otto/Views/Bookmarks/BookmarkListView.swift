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
                OttoVerticalDivider()

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
            // Header — no hairline underneath; content scrolls directly below.
            header

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
            HStack(alignment: .center, spacing: 10) {
                Text("Bookmarks")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                OttoCountChip(text: "\(appState.bookmarks.count) · \(unreadCount) unread")

                Spacer()
            }

            // Filters — read-state pills left, media pills right. The narrow
            // list pane (400pt when the detail panel is open) falls back to a
            // horizontal scroll so the pills can never compress into
            // letter-wrapped text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.md) {
                    BookmarkFilterPicker(selection: $filter)
                    Spacer(minLength: Theme.Spacing.md)
                    mediaTypePills
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        BookmarkFilterPicker(selection: $filter)
                        mediaTypePills
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var unreadCount: Int {
        appState.bookmarks.filter { !$0.isRead }.count
    }

    private var mediaTypePills: some View {
        OttoPillRail(options: mediaTypeOptions, selection: $mediaFilter)
    }

    private var mediaTypeOptions: [(value: Bookmark.MediaType?, label: String)] {
        [
            (nil, "All"),
            (.readLater, "Read Later"),
            (.listenLater, "Listen Later"),
            (.watchLater, "Watch Later"),
        ]
    }

    // MARK: - Bookmark List

    private var bookmarkList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
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
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "bookmark",
            title: emptyStateTitle,
            message: "Paste a URL to save it for later.",
            tip: "Saved links become readable by the agent"
        )
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
