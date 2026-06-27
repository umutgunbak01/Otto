import SwiftUI

struct EventListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .date
    @State private var filterType: EventType? = nil
    @State private var filterStatus: EventStatus? = nil
    @State private var editing: EditingTarget?

    enum SortOption: String, CaseIterable {
        case date = "Date"
        case name = "Name"
        case recent = "Recent"
    }

    struct EditingTarget: Identifiable {
        let id: UUID
        let event: Event?
    }

    var filtered: [Event] {
        var result = appState.events

        if !searchText.isEmpty {
            result = result.filter { $0.searchableContent.localizedCaseInsensitiveContains(searchText) }
        }
        if let type = filterType {
            result = result.filter { $0.type == type }
        }
        if let status = filterStatus {
            result = result.filter { $0.status == status }
        }

        switch sortOption {
        case .date:
            // Upcoming first (ascending by date), then undated, then past.
            result.sort { lhs, rhs in
                let l = lhs.startDate ?? Date.distantFuture
                let r = rhs.startDate ?? Date.distantFuture
                return l < r
            }
        case .name:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .recent:
            result.sort { $0.updatedAt > $1.updatedAt }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            if appState.events.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { event in
                            EventRow(event: event) {
                                editing = EditingTarget(id: event.id, event: event)
                            }
                            OttoDivider()
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            EventEditorSheet(event: target.event)
                .environment(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("◈ EVENTS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filtered.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                Button {
                    editing = EditingTarget(id: UUID(), event: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11))
                        Text("New").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.Colors.hoverTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .frame(maxWidth: 260)

                // Status filter
                Menu {
                    Button { filterStatus = nil } label: {
                        HStack { Text("All"); if filterStatus == nil { Image(systemName: "checkmark") } }
                    }
                    Divider()
                    ForEach(EventStatus.allCases) { status in
                        Button { filterStatus = status } label: {
                            HStack {
                                Image(systemName: status.icon)
                                Text(status.label)
                                if filterStatus == status { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    filterChipLabel(icon: "flag", text: filterStatus?.label ?? "Status", isActive: filterStatus != nil)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Type filter
                Menu {
                    Button { filterType = nil } label: {
                        HStack { Text("All Types"); if filterType == nil { Image(systemName: "checkmark") } }
                    }
                    Divider()
                    ForEach(EventType.allCases) { type in
                        Button { filterType = type } label: {
                            HStack {
                                Image(systemName: type.icon)
                                Text(type.label)
                                if filterType == type { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    filterChipLabel(icon: "square.grid.2x2", text: filterType?.label ?? "Type", isActive: filterType != nil)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Sort
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button { sortOption = option } label: {
                            HStack { Text(option.rawValue); if sortOption == option { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    filterChipLabel(icon: "arrow.up.arrow.down", text: sortOption.rawValue, isActive: false)
                }
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

    private func filterChipLabel(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Theme.Colors.accent.opacity(0.1) : Theme.Colors.borderSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No events yet")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Button { editing = EditingTarget(id: UUID(), event: nil) } label: {
                Text("Add an event").font(.system(size: 13)).foregroundStyle(Theme.Colors.accent)
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
            Text("No results")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Button {
                searchText = ""; filterType = nil; filterStatus = nil
            } label: {
                Text("Clear filters").font(.system(size: 13)).foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event
    let onOpen: () -> Void
    @State private var isHovered = false

    private var neon: Color { event.type == .unknown ? ContentType.event.color : event.type.color }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(neon.opacity(isHovered ? 0.22 : 0.12))
                        .frame(width: 32, height: 32)
                        .shadow(color: neon.opacity(isHovered ? 0.7 : 0), radius: isHovered ? 8 : 0)
                    Image(systemName: event.type.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(neon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name.isEmpty ? "Untitled" : event.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHovered ? neon : Theme.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(event.type.label)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        if !event.location.isEmpty {
                            Image(systemName: "mappin.circle").font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(event.location).foregroundStyle(Theme.Colors.tertiaryText).lineLimit(1)
                        }
                        if !event.dateRangeText.isEmpty {
                            Image(systemName: "calendar").font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(event.dateRangeText).foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                    .font(.system(size: 11))
                }

                Spacer(minLength: 0)

                statusBadge

                if let budget = event.formattedBudget {
                    Text(budget)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.amber)
                }
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: event.status.icon).font(.system(size: 9))
            Text(event.status.label).font(.system(size: 10))
        }
        .foregroundStyle(event.status.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(event.status.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

#Preview {
    EventListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
