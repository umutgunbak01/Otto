import SwiftUI

struct CommunityListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .name
    @State private var filterType: CommunityType? = nil
    @State private var perkOnly: Bool = false
    @State private var editing: EditingTarget?

    enum SortOption: String, CaseIterable { case name = "Name", recent = "Recent", type = "Type" }

    struct EditingTarget: Identifiable { let id: UUID; let community: Community? }

    var filtered: [Community] {
        var result = appState.communities
        if !searchText.isEmpty {
            result = result.filter { $0.searchableContent.localizedCaseInsensitiveContains(searchText) }
        }
        if let type = filterType { result = result.filter { $0.type == type } }
        if perkOnly { result = result.filter { $0.builderSupportPerk } }
        switch sortOption {
        case .name: result.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .recent: result.sort { $0.updatedAt > $1.updatedAt }
        case .type: result.sort { $0.type.label < $1.type.label }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            viewbar
            if appState.communities.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { community in
                            CommunityRow(community: community) {
                                editing = EditingTarget(id: community.id, community: community)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xxl)
                    .frame(maxWidth: 828)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $editing) { target in
            CommunityEditorSheet(community: target.community).environment(appState)
        }
    }

    // MARK: - Viewbar

    private var viewbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Communities")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(filtered.count)")

            OttoPillRail(
                options: [(value: false, label: "All"), (value: true, label: "Builder Perk")],
                selection: $perkOnly
            )

            Spacer(minLength: 8)

            // Type filter
            Menu {
                Button { filterType = nil } label: { Text("All Types") }
                Divider()
                ForEach(CommunityType.allCases) { t in
                    Button { filterType = t } label: { Label(t.label, systemImage: t.icon) }
                }
            } label: {
                OttoBarButtonLabel(label: filterType?.label ?? "Type", showsCaret: true)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif

            // Sort
            Menu {
                ForEach(SortOption.allCases, id: \.self) { o in
                    Button { sortOption = o } label: { Text(o.rawValue) }
                }
            } label: {
                OttoBarButtonLabel(label: "Sort: \(sortOption.rawValue)", showsCaret: true)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif

            OttoSearchMini(placeholder: "Search communities…", text: $searchText)

            OttoNewButton(label: "New") {
                editing = EditingTarget(id: UUID(), community: nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "bubble.left.and.bubble.right",
            title: "No communities yet",
            message: "Track the communities, societies and collectives worth engaging — and which offer builder perks."
        ) {
            OttoSuggestionChip(systemImage: "plus", label: "Add a community") {
                editing = EditingTarget(id: UUID(), community: nil)
            }
        }
    }

    private var noResultsState: some View {
        OttoEmptyState(
            systemImage: "magnifyingglass",
            title: "No matches",
            message: "Nothing fits the current search and filters."
        ) {
            OttoSuggestionChip(systemImage: "arrow.counterclockwise", label: "Clear filters") {
                searchText = ""; filterType = nil; perkOnly = false
            }
        }
    }
}

// MARK: - Community Row

private struct CommunityRow: View {
    let community: Community
    let onOpen: () -> Void
    @State private var isHovered = false

    /// Stable per-community square tint — violet/teal/green rotation by
    /// name hash, so a given community keeps its color across launches.
    private static let palette: [Color] = [
        Theme.Colors.violet, Theme.Colors.cyan, Theme.Colors.green,
    ]

    private var squareColor: Color {
        var hash: UInt64 = 1469598103934665603
        for byte in community.name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                OttoSquare(systemImage: "bubble.left.and.bubble.right", color: squareColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(community.name.isEmpty ? "Untitled" : community.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)
                        if community.builderSupportPerk {
                            Text("PERK")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(Theme.Colors.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Colors.tintAmber))
                                .overlay(Capsule().strokeBorder(Theme.Colors.amber.opacity(0.2), lineWidth: 1))
                        }
                    }

                    HStack(spacing: 6) {
                        Text(community.type.label)
                        if !community.location.isEmpty {
                            Image(systemName: "mappin")
                                .font(.system(size: 11))
                            Text(community.location)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // Quiet list row — no border, wash on hover.
            RoundedRectangle(cornerRadius: 11)
                .fill(isHovered ? Theme.Colors.panel : Color.clear)
        )
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering } }
    }
}

#Preview {
    CommunityListView().environment(AppState()).frame(width: 1000, height: 700)
}
