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
        HStack(alignment: .center, spacing: 10) {
            Text("Meetings")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(filteredMeetings.count)")

            Spacer(minLength: 8)

            // Search scope pills — only affect filtering while a query is
            // typed, so they can stay visible at all times.
            OttoPillRail(
                options: SearchScope.allCases.map { (value: $0, label: $0.rawValue) },
                selection: $searchScope
            )

            OttoSearchMini(placeholder: "Search meetings…", text: $searchText, width: 200)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Meeting List

    /// Display-only date grouping over `filteredMeetings` — the filtered
    /// array (and its sort order) is the source of truth; this just buckets
    /// it for OttoGroupLabel headers.
    private var groupedMeetings: [(label: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let now = Date()
        let lastWeekDate = calendar.date(byAdding: .weekOfYear, value: -1, to: now)

        var thisWeek: [Meeting] = []
        var lastWeek: [Meeting] = []
        var earlier: [Meeting] = []

        for meeting in filteredMeetings {
            if calendar.isDate(meeting.meetingDate, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(meeting)
            } else if let lastWeekDate,
                      calendar.isDate(meeting.meetingDate, equalTo: lastWeekDate, toGranularity: .weekOfYear) {
                lastWeek.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }

        var groups: [(label: String, meetings: [Meeting])] = []
        if !thisWeek.isEmpty { groups.append(("This week", thisWeek)) }
        if !lastWeek.isEmpty { groups.append(("Last week", lastWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // A just-finished recording being analyzed in the background —
                // becomes a real Meeting row when the note lands.
                if searchText.isEmpty, let pendingTitle = MeetingAnalysisService.shared.pendingTitle {
                    generatingRow(title: pendingTitle)
                        .padding(.top, 4)
                }
                ForEach(groupedMeetings, id: \.label) { group in
                    OttoGroupLabel(text: group.label, count: group.meetings.count)

                    ForEach(group.meetings) { meeting in
                        MeetingRowView(meeting: meeting)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                navigationPath.append(meeting.id)
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
    }

    private func generatingRow(title: String) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.Colors.tintTeal)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                Text("Generating meeting note…")
                    .font(Theme.Typography.displaySm)
                    .italic()
                    .foregroundStyle(Theme.Colors.textDim)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Theme.Colors.panel)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "video",
            title: searchText.isEmpty ? "No meetings yet" : "No matching meetings",
            message: "Import meetings from Fireflies.ai via Integrations, or let Otto transcribe calls it detects.",
            tip: "Otto offers to transcribe when a meeting app uses the mic"
        )
    }
}

#Preview {
    MeetingListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
