import SwiftUI

struct MeetingRowView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Meeting icon
            ZStack {
                Rectangle()
                    .fill(Theme.Colors.cyan.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .overlay(Rectangle().stroke(Theme.Colors.cyan.opacity(0.3), lineWidth: 1))

                Image(systemName: "video.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.cyan)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Title
                Text(meeting.title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)

                // Meeting date and duration
                HStack(spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text(meeting.formattedMeetingDate)
                    }

                    if meeting.duration > 0 {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(meeting.formattedDuration)
                        }
                    }
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.secondaryText)

                // Participants preview
                if !meeting.participants.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "person.2")
                            .font(.system(size: 10))
                        Text(participantsPreview)
                            .lineLimit(1)
                    }
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Tags
                if !meeting.domainTagIds.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(appState.tags(for: meeting.domainTagIds).prefix(3)) { tag in
                            TagChipView(tag: tag, isCompact: true)
                        }
                    }
                }
            }

            Spacer()

            // Selection indicator
            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
            }
        }
        .padding(Theme.Spacing.md)
        .ottoRow(isSelected: isSelected)
    }

    private var participantsPreview: String {
        let names = meeting.participants.prefix(3)
        let preview = names.joined(separator: ", ")
        if meeting.participants.count > 3 {
            return preview + " +\(meeting.participants.count - 3)"
        }
        return preview
    }
}

#Preview {
    VStack(spacing: 0) {
        MeetingRowView(
            meeting: Meeting(
                title: "Product Strategy Meeting",
                overview: "Discussed Q1 roadmap",
                participants: ["Alice", "Bob", "Charlie", "Diana"],
                organizer: "alice@company.com",
                duration: 2700,
                meetingDate: Date()
            ),
            isSelected: false
        )
        MeetingRowView(
            meeting: Meeting(
                title: "Sprint Planning",
                overview: "Planning for next sprint",
                participants: ["Team Lead", "Developer"],
                duration: 1800,
                meetingDate: Date().addingTimeInterval(-86400)
            ),
            isSelected: true
        )
    }
    .padding()
    .environment(AppState())
}
