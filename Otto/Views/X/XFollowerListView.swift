import SwiftUI

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
            // Header
            VStack(spacing: Theme.Spacing.sm) {
                HStack(alignment: .center, spacing: 8) {
                    Text("X Followers")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.text)

                    Spacer()

                    OttoCountBadge(count: filteredFollowers.count)

                    // Loading indicator
                    if appState.isLoadingX {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    }
                }

                // Scope pills — view everyone or only mutuals — plus sort menu
                HStack(spacing: 4) {
                    ForEach(FilterScope.allCases) { scope in
                        Button {
                            filterScopeRaw = scope.rawValue
                        } label: {
                            Text(scope.label)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(filterScope == scope ? Theme.Colors.selectTint : Color.clear)
                                )
                                .foregroundStyle(
                                    filterScope == scope ? Theme.Colors.accentText : Theme.Colors.textDim
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

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
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 9))
                            Text(sortOption.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.Colors.textDim)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort followers")
                }

                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.bgInput)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            OttoDivider()

            // Follower list
            if filteredFollowers.isEmpty && appState.xFollowers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No X followers yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("Connect X in Integrations to import your followers. Mutuals are highlighted.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredFollowers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No results")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Button {
                        searchText = ""
                    } label: {
                        Text("Clear search")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredFollowers) { follower in
                            sidebarFollowerRow(follower)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.Colors.bg1)
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
                    HStack(spacing: 4) {
                        Text(follower.displayLabel)
                            .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.secondaryText)
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
                            .font(.system(size: 11.5, design: .monospaced))
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
                VStack(alignment: .trailing, spacing: 3) {
                    if follower.isMutual {
                        AngularChip(fill: Theme.Colors.selectTint) {
                            Text("Mutual")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.accentText)
                        }
                    }

                    HStack(spacing: 2) {
                        Text(OttoFormatters.compactCount(follower.followersCount))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Image(systemName: "person.2")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .ottoRow(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty Editor

    private var emptyEditor: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))

            Text("Select a follower")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("Choose a follower from the sidebar to view details")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    XFollowerListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
