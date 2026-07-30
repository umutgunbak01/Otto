import SwiftUI

struct MeetingRowView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            // Meeting icon square (mockup .sq) — dim when no transcript.
            OttoSquare(systemImage: "video", color: Theme.Colors.cyan, dim: !meeting.hasTranscript)

            VStack(alignment: .leading, spacing: 3) {
                // Title
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                // Participants + tags sub-line
                HStack(spacing: 8) {
                    if !meeting.participants.isEmpty {
                        Text(participantsPreview)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }

                    ForEach(appState.tags(for: meeting.domainTagIds).prefix(3)) { tag in
                        TagChipView(tag: tag, isCompact: true)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            // Action-items + transcript chips + date/duration (mockup .end)
            HStack(spacing: Theme.Spacing.sm) {
                if actionItemCount > 0 {
                    monoCapsule(
                        "\(actionItemCount) action item\(actionItemCount == 1 ? "" : "s")",
                        color: Theme.Colors.amber
                    )
                }

                if meeting.hasTranscript {
                    monoCapsule("transcript", color: Theme.Colors.green)
                } else {
                    dimCapsule("no transcript")
                }

                Text(dateAndDuration)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 9)
        .background(
            // Quiet list row (mockup .lrow) — no border, wash on hover,
            // teal tint when selected.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered ? Theme.Colors.panel : Color.clear)
                )
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    // MARK: - Chips

    /// Colored mono capsule (mockup .chip2 semantic chips).
    private func monoCapsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1))
    }

    /// Neutral dim capsule for the "no transcript" state.
    private func dimCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.Colors.panel))
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
    }

    /// The model stores action items as newline-separated markdown text —
    /// count the non-empty lines for the chip.
    private var actionItemCount: Int {
        meeting.actionItems
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
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
