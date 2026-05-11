import SwiftUI

struct MeetingListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var searchScope: SearchScope = .titleOnly
    @State private var navigationPath = NavigationPath()

    enum SearchScope: String, CaseIterable {
        case titleOnly = "Title"
        case titleAndContent = "All Content"

        var description: String {
            switch self {
            case .titleOnly: return "Search titles only"
            case .titleAndContent: return "Search titles, notes, and action items"
            }
        }
    }

    var filteredMeetings: [Meeting] {
        let sorted = appState.meetings.sorted { $0.meetingDate > $1.meetingDate }

        if searchText.isEmpty {
            return sorted
        }

        return sorted.filter { meeting in
            switch searchScope {
            case .titleOnly:
                return meeting.title.localizedCaseInsensitiveContains(searchText) ||
                       meeting.participants.contains { $0.localizedCaseInsensitiveContains(searchText) }
            case .titleAndContent:
                return meeting.title.localizedCaseInsensitiveContains(searchText) ||
                       meeting.overview.localizedCaseInsensitiveContains(searchText) ||
                       meeting.actionItems.localizedCaseInsensitiveContains(searchText) ||
                       meeting.content.localizedCaseInsensitiveContains(searchText) ||
                       meeting.participants.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listPanel
                .navigationDestination(for: UUID.self) { meetingId in
                    if let meeting = appState.meetings.first(where: { $0.id == meetingId }) {
                        MeetingDetailView(meeting: meeting)
                    }
                }
        }
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.meetings.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.meetings.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()

            if filteredMeetings.isEmpty {
                emptyState
            } else {
                meetingList
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("⌬ MEETINGS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filteredMeetings.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()
            }

            // Search field
            VStack(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    TextField("Search meetings...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.borderSubtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                // Search scope picker (visible when searching)
                if !searchText.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Search in:")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    searchScope = scope
                                }
                            } label: {
                                Text(scope.rawValue)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(searchScope == scope ? Theme.Colors.bg0 : Theme.Colors.secondaryText)
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, Theme.Spacing.xs)
                                    .background(
                                        searchScope == scope
                                            ? Theme.Colors.accent
                                            : Theme.Colors.borderSubtle
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Meeting List

    private var meetingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredMeetings) { meeting in
                    MeetingRowView(meeting: meeting)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(meeting.id)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "video")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(searchText.isEmpty ? "No meetings yet" : "No matching meetings")
                    .font(Theme.Typography.title)
                Text("Import meetings from Fireflies.ai via Integrations")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    MeetingListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
