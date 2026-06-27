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
            header
            OttoDivider()
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
                            OttoDivider()
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            CommunityEditorSheet(community: target.community).environment(appState)
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("❖ COMMUNITIES")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(ContentType.community.color)
                    .shadow(color: ContentType.community.color.opacity(0.6), radius: 4)

                Text("\(filtered.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                Button { editing = EditingTarget(id: UUID(), community: nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("New").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.Colors.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Spacing.sm) {
                TableSearchField(text: $searchText, placeholder: "Search communities…")
                Button { perkOnly.toggle() } label: {
                    TableFilterChip(icon: "gift", text: "Builder Perk", isActive: perkOnly)
                }
                .buttonStyle(.plain)
                Menu {
                    Button { filterType = nil } label: { Text("All Types") }
                    Divider()
                    ForEach(CommunityType.allCases) { t in
                        Button { filterType = t } label: { Label(t.label, systemImage: t.icon) }
                    }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: filterType?.label ?? "Type", isActive: filterType != nil) }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { o in Button { sortOption = o } label: { Text(o.rawValue) } }
                } label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sortOption.rawValue, isActive: false) }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No communities yet").font(.system(size: 15)).foregroundStyle(Theme.Colors.tertiaryText)
            Button { editing = EditingTarget(id: UUID(), community: nil) } label: {
                Text("Add a community").font(.system(size: 13)).foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No results").font(.system(size: 15)).foregroundStyle(Theme.Colors.tertiaryText)
            Button { searchText = ""; filterType = nil; perkOnly = false } label: {
                Text("Clear filters").font(.system(size: 13)).foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CommunityRow: View {
    let community: Community
    let onOpen: () -> Void
    @State private var isHovered = false
    private var neon: Color { community.type.color }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(neon.opacity(isHovered ? 0.22 : 0.12))
                        .frame(width: 32, height: 32)
                        .shadow(color: neon.opacity(isHovered ? 0.7 : 0), radius: isHovered ? 8 : 0)
                    Image(systemName: community.type.icon).font(.system(size: 13)).foregroundStyle(neon)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(community.name.isEmpty ? "Untitled" : community.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHovered ? neon : Theme.Colors.text)
                            .lineLimit(1)
                        if community.builderSupportPerk {
                            Text("PERK")
                                .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundStyle(Theme.Colors.amber)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Rectangle().stroke(Theme.Colors.amber.opacity(0.5), lineWidth: 1))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(community.type.label).foregroundStyle(Theme.Colors.tertiaryText)
                        if !community.location.isEmpty {
                            Image(systemName: "mappin.circle").font(.system(size: 9)).foregroundStyle(Theme.Colors.tertiaryText)
                            Text(community.location).foregroundStyle(Theme.Colors.tertiaryText).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(neon.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, Theme.Spacing.md)
        )
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering } }
    }
}

#Preview {
    CommunityListView().environment(AppState()).frame(width: 1000, height: 700)
}
