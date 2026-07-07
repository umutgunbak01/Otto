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
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { event in
                            EventRow(event: event) {
                                editing = EditingTarget(id: event.id, event: event)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
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
            HStack(alignment: .center, spacing: 10) {
                Text("Events")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountBadge(count: filtered.count)

                Spacer()

                Button {
                    editing = EditingTarget(id: UUID(), event: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        Text("New").font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(AccentButtonStyle())
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
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Colors.bgInput)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
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
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.textDim)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Theme.Colors.selectTint : Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isActive ? Color.clear : Theme.Colors.border, lineWidth: 1)
        )
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
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(neon.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: event.type.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(neon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name.isEmpty ? "Untitled" : event.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(event.type.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textDim)
                        if !event.location.isEmpty {
                            Image(systemName: "mappin.circle").font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textDim)
                            Text(event.location)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.textDim)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                statusBadge

                if !event.dateRangeText.isEmpty {
                    Text(event.dateRangeText)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                if let budget = event.formattedBudget {
                    Text(budget)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.green)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    /// Mockup chip colors: hosting/attending → accent "Scheduled" look,
    /// considering → amber "Planning" look, declined → dim "Completed" look.
    private var statusChipColors: (fg: Color, bg: Color) {
        switch event.status {
        case .hosting:     return (Theme.Colors.accentText, Theme.Colors.selectTint)
        case .attending:   return (Theme.Colors.green, Theme.Colors.tintGreen)
        case .considering: return (Theme.Colors.amber, Theme.Colors.tintAmber)
        case .declined:    return (Theme.Colors.tertiaryText, Theme.Colors.hoverTint)
        }
    }

    private var statusBadge: some View {
        Text(event.status.label)
            .font(Theme.Typography.monoSmall)
            .foregroundStyle(statusChipColors.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusChipColors.bg)
            )
    }
}

#Preview {
    EventListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
