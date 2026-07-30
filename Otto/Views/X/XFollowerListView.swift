import SwiftUI

/// Teal mono "Mutual" capsule — accent text on a teal wash with a faint
/// cyan hairline (mockup .mutual).
struct XMutualChip: View {
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .medium))
            }
            Text("Mutual")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Theme.Colors.accentText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.Colors.tintTeal))
        .overlay(Capsule().strokeBorder(Theme.Colors.cyan.opacity(0.2), lineWidth: 1))
    }
}

struct XFollowerListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var selectedFollowerId: UUID?
    @State private var isSidebarCollapsed: Bool = false
    /// Persistent display filter: "all" shows everyone who follows the
    /// user, "mutuals" hides accounts the user doesn't follow back.
    /// Stored in UserDefaults so the choice survives relaunches.
    @AppStorage("x_followers_filter_scope") private var filterScopeRaw: String = FilterScope.all.rawValue
    @AppStorage("x_followers_sort") private var sortOptionRaw: String = SortOption.followers.rawValue

    private enum FilterScope: String, CaseIterable, Identifiable {
        case all
        case mutuals
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:     return "All"
            case .mutuals: return "Mutuals"
            }
        }
    }

    private enum SortOption: String, CaseIterable, Identifiable {
        case followers
        case name
        case recentlySynced

        var id: String { rawValue }
        var label: String {
            switch self {
            case .followers:      return "Followers"
            case .name:           return "Name"
            case .recentlySynced: return "Recently synced"
            }
        }
    }

    private var filterScope: FilterScope {
        FilterScope(rawValue: filterScopeRaw) ?? .all
    }

    private var sortOption: SortOption {
        SortOption(rawValue: sortOptionRaw) ?? .followers
    }

    var filteredFollowers: [XFollower] {
        var result = appState.xFollowers

        // Mutuals-only filter (applied first so the search box and count
        // badge reflect what the user has scoped to).
        if filterScope == .mutuals {
            result = result.filter { $0.isMutual }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { follower in
                follower.username.localizedCaseInsensitiveContains(searchText) ||
                follower.displayName.localizedCaseInsensitiveContains(searchText) ||
                follower.bio.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOption {
        case .followers:
            // Notable accounts first; a name tiebreak keeps the order
            // stable across the long tail of zero-follower accounts.
            result.sort {
                if $0.followersCount != $1.followersCount {
                    return $0.followersCount > $1.followersCount
                }
                return $0.displayLabel.lowercased() < $1.displayLabel.lowercased()
            }
        case .name:
            // Sort on displayLabel so punctuation-named accounts don't
            // clump at the top.
            result.sort { $0.displayLabel.lowercased() < $1.displayLabel.lowercased() }
        case .recentlySynced:
            result.sort { $0.syncUpdatedAt > $1.syncUpdatedAt }
        }

        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar with follower list (collapsible)
            if !isSidebarCollapsed {
                followerSidebar
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.Colors.border)
                    .frame(width: 1)
            }

            // Detail view
            if let followerId = selectedFollowerId,
               let follower = appState.xFollowers.first(where: { $0.id == followerId }) {
                XFollowerDetailView(
                    follower: follower,
                    isSidebarCollapsed: isSidebarCollapsed,
                    onToggleSidebar: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarCollapsed.toggle()
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .id(followerId)
            } else {
                emptyEditor
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.15), value: selectedFollowerId)
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.xFollowers.contains(where: { $0.id == itemId }) {
                selectedFollowerId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.xFollowers.contains(where: { $0.id == itemId }) {
                selectedFollowerId = itemId
                appState.locateItemId = nil
            }
            // Auto-select first follower if none selected
            if selectedFollowerId == nil, let first = filteredFollowers.first {
                selectedFollowerId = first.id
            }
        }
    }

    // MARK: - Follower Sidebar

    private var followerSidebar: some View {
        VStack(spacing: 0) {
            // Viewbar — serif title + count chip, then scope pills + sort,
            // then search. No hairline beneath.
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Followers")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Colors.text)

                    OttoCountChip(text: "\(filteredFollowers.count)")

                    Spacer(minLength: 8)

                    // Loading indicator
                    if appState.isLoadingX {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    }
                }

                // Scope pills — view everyone or only mutuals — plus sort menu
                HStack(spacing: 8) {
                    OttoPillRail(
                        options: FilterScope.allCases.map { (value: $0, label: $0.label) },
                        selection: Binding(
                            get: { filterScope },
                            set: { filterScopeRaw = $0.rawValue }
                        )
                    )

                    Spacer(minLength: 4)

                    Menu {
                        ForEach(SortOption.allCases) { option in
                            Button {
                                sortOptionRaw = option.rawValue
                            } label: {
                                HStack {
                                    Text(option.label)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        OttoBarButtonLabel(label: sortOption.label, showsCaret: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort followers")
                }

                // Search field
                OttoSearchMini(placeholder: "Search followers…", text: $searchText, width: nil)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Follower list
            if filteredFollowers.isEmpty && appState.xFollowers.isEmpty {
                OttoEmptyState(
                    systemImage: "person.2",
                    title: "No followers yet",
                    message: "Connect X in Integrations to import your followers. Mutuals are highlighted."
                )
            } else if filteredFollowers.isEmpty {
                OttoEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No results",
                    message: "Nothing matches the current filters."
                ) {
                    OttoSuggestionChip(systemImage: "xmark", label: "Clear search") {
                        searchText = ""
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredFollowers) { follower in
                            sidebarFollowerRow(follower)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.lg)
                }
            }
        }
        .background(Theme.Colors.panelWash)
    }

    // MARK: - Sidebar Follower Row

    private func sidebarFollowerRow(_ follower: XFollower) -> some View {
        let isSelected = selectedFollowerId == follower.id

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedFollowerId = follower.id
            }
        } label: {
            HStack(spacing: 10) {
                // Real profile photo, initials fallback
                XProfileImage(
                    urlString: follower.profileImageUrl,
                    seed: follower.username,
                    initials: follower.initials,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(follower.displayLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)

                        // Linked badge
                        if follower.linkedConnectionId != nil {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                    }

                    // Skip the handle line when it's already the title
                    if follower.hasMeaningfulName {
                        Text("@\(follower.username)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }

                    if !follower.bio.isEmpty {
                        Text(follower.bio)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Mutual chip + follower count
                VStack(alignment: .trailing, spacing: 4) {
                    if follower.isMutual {
                        XMutualChip()
                    }

                    HStack(spacing: 3) {
                        Text(OttoFormatters.compactCount(follower.followersCount))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Image(systemName: "person.2")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .xRowCard(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty Editor

    private var emptyEditor: some View {
        OttoEmptyState(
            systemImage: "person.2",
            title: "Select a follower",
            message: "Choose a follower from the sidebar to view details."
        )
    }
}

#Preview {
    XFollowerListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
