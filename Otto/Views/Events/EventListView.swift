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

    private var upcoming: [Event] { filtered.filter(\.isUpcoming) }
    private var past: [Event] { filtered.filter { !$0.isUpcoming } }

    var body: some View {
        VStack(spacing: 0) {
            viewbar
            if appState.events.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !upcoming.isEmpty {
                            OttoGroupLabel(text: "Upcoming", count: upcoming.count)
                            ForEach(upcoming) { event in
                                EventRow(event: event) {
                                    editing = EditingTarget(id: event.id, event: event)
                                }
                            }
                        }
                        if !past.isEmpty {
                            OttoGroupLabel(text: "Past", count: past.count)
                            ForEach(past) { event in
                                EventRow(event: event) {
                                    editing = EditingTarget(id: event.id, event: event)
                                }
                                .opacity(0.55)
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
            EventEditorSheet(event: target.event)
                .environment(appState)
        }
    }

    // MARK: - Viewbar

    private var viewbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Events")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(filtered.count)")

            Spacer(minLength: 8)

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
                OttoBarButtonLabel(label: filterStatus?.label ?? "Status", showsCaret: true)
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
                OttoBarButtonLabel(label: filterType?.label ?? "Type", showsCaret: true)
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
                OttoBarButtonLabel(label: "Sort: \(sortOption.rawValue)", showsCaret: true)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif

            OttoSearchMini(placeholder: "Search", text: $searchText)

            OttoNewButton(label: "New") {
                editing = EditingTarget(id: UUID(), event: nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "calendar",
            title: "No events yet",
            message: "Conferences, summits, dinners — track where to show up, who's going, and what it costs."
        ) {
            OttoSuggestionChip(systemImage: "plus", label: "Add an event") {
                editing = EditingTarget(id: UUID(), event: nil)
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
                searchText = ""; filterType = nil; filterStatus = nil
            }
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                // Teal when upcoming, violet while still considering, dim once past.
                OttoSquare(
                    systemImage: "calendar",
                    color: event.status == .considering ? Theme.Colors.violet : Theme.Colors.cyan,
                    dim: !event.isUpcoming
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name.isEmpty ? "Untitled" : event.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(event.type.label)
                        if !event.location.isEmpty {
                            Image(systemName: "mappin")
                                .font(.system(size: 11))
                            Text(event.location)
                                .lineLimit(1)
                        }
                        if !event.linkedConnectionIds.isEmpty {
                            Text("· \(event.linkedConnectionIds.count) attendees")
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer(minLength: 12)

                statusChip

                if !event.dateRangeText.isEmpty {
                    Text(event.dateRangeText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                if let budget = event.formattedBudget {
                    Text(budget)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.green)
                }
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    /// Chip tones: hosting → teal "Scheduled" look, attending → green,
    /// considering → amber "Planning" look, declined → dim "Completed" look.
    private var chipColors: (fg: Color, bg: Color, stroke: Color) {
        switch event.status {
        case .hosting:     return (Theme.Colors.accentText, Theme.Colors.tintTeal, Theme.Colors.cyan.opacity(0.2))
        case .attending:   return (Theme.Colors.green, Theme.Colors.tintGreen, Theme.Colors.green.opacity(0.2))
        case .considering: return (Theme.Colors.amber, Theme.Colors.tintAmber, Theme.Colors.amber.opacity(0.2))
        case .declined:    return (Theme.Colors.tertiaryText, Theme.Colors.hoverTint, Theme.Colors.border)
        }
    }

    private var statusChip: some View {
        Text(event.status.label)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(chipColors.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(chipColors.bg))
            .overlay(Capsule().strokeBorder(chipColors.stroke, lineWidth: 1))
    }
}

#Preview {
    EventListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
