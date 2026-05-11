import SwiftUI

struct TranscriptRowView: View {
    let transcript: FirefliesTranscript
    let isSelected: Bool
    let isImported: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isImported ? Theme.Colors.personal.opacity(0.1) : Theme.Colors.hobby.opacity(0.1))
                    .frame(width: 36, height: 36)

                Image(systemName: isImported ? "checkmark.circle.fill" : "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(isImported ? Theme.Colors.personal : Theme.Colors.hobby)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(transcript.title ?? "Untitled Meeting")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.sm) {
                    if transcript.date != nil {
                        Text(transcript.formattedDate)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    if transcript.duration != nil {
                        Text(transcript.formattedDuration)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            Spacer()

            if isImported {
                Text("Imported")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.personal)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.personal.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    VStack {
        TranscriptRowView(
            transcript: FirefliesTranscript(
                id: "1",
                title: "Weekly Team Standup",
                date: 1705744800000, // Jan 20, 2025 10:00 UTC in milliseconds
                duration: 30, // 30 minutes
                organizer_email: "test@example.com",
                participants: ["Alice", "Bob"],
                summary: nil
            ),
            isSelected: false,
            isImported: false
        )

        TranscriptRowView(
            transcript: FirefliesTranscript(
                id: "2",
                title: "Product Review",
                date: 1705672800000, // Jan 19, 2025 14:00 UTC in milliseconds
                duration: 60, // 60 minutes
                organizer_email: "test@example.com",
                participants: nil,
                summary: nil
            ),
            isSelected: true,
            isImported: true
        )
    }
    .padding()
}
