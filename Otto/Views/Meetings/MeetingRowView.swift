import SwiftUI

struct MeetingRowView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            // Meeting icon (mockup .sq)
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.Colors.selectTint)
                    .frame(width: 30, height: 30)

                Image(systemName: "video.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.accentText)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Title
                Text(meeting.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                // Participants + tags sub-line
                HStack(spacing: 10) {
                    if !meeting.participants.isEmpty {
                        Text(participantsPreview)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                    }

                    ForEach(appState.tags(for: meeting.domainTagIds).prefix(3)) { tag in
                        TagChipView(tag: tag, isCompact: true)
                    }
                }
            }

            Spacer()

            // Transcript chip + date/duration (mockup .end)
            HStack(spacing: Theme.Spacing.sm) {
                if meeting.firefliesId != nil {
                    AngularChip(fill: Theme.Colors.tintGreen) {
                        Text("transcript")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.green)
                    }
                } else {
                    AngularChip {
                        Text("no transcript")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }

                Text(dateAndDuration)
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.selectTint : Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var dateAndDuration: String {
        if meeting.duration > 0 {
            return "\(meeting.formattedMeetingDate) · \(meeting.formattedDuration)"
        }
        return meeting.formattedMeetingDate
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
    VStack(spacing: 6) {
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
