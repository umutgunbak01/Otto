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

            if filteredMeetings.isEmpty && MeetingAnalysisService.shared.pendingTitle == nil {
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
            HStack(alignment: .center, spacing: 10) {
                Text("Meetings")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountBadge(count: filteredMeetings.count)

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
                        .font(Theme.Typography.callout)

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
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Colors.bgInput)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )

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
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(searchScope == scope ? Theme.Colors.accentText : Theme.Colors.textDim)
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, Theme.Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(searchScope == scope ? Theme.Colors.selectTint : Color.clear)
                                    )
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
            LazyVStack(spacing: 6) {
                // A just-finished recording being analyzed in the background —
                // becomes a real Meeting row when the note lands.
                if searchText.isEmpty, let pendingTitle = MeetingAnalysisService.shared.pendingTitle {
                    generatingRow(title: pendingTitle)
                }
                ForEach(filteredMeetings) { meeting in
                    MeetingRowView(meeting: meeting)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigationPath.append(meeting.id)
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func generatingRow(title: String) -> some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.Colors.selectTint)
                    .frame(width: 30, height: 30)

                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                Text("Generating meeting note…")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textDim)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.bg2)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        )
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
