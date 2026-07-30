import SwiftUI

struct CalendarEventRowView: View {
    let event: CalendarEvent

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            // Teal fading spine (mockup .erow .bar).
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [Theme.Colors.cyan, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2, height: 34)

            // Time range
            Text(event.formattedTimeRange)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textDim)
                .frame(width: 76, alignment: .leading)

            // Event title
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(event.isPast ? Theme.Colors.textDim : Theme.Colors.text)
                    .lineLimit(1)

                // Location or attendees preview
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                } else if !event.attendees.isEmpty {
                    Text(attendeesPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Hover action - open in Google Calendar
            if isHovered, let htmlLink = event.htmlLink, let url = URL(string: htmlLink) {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Open in Google Calendar")
                #endif
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(isHovered ? Theme.Colors.panel : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let htmlLink = event.htmlLink, let url = URL(string: htmlLink) {
                openURL(url)
            }
        }
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var attendeesPreview: String {
        let names = event.attendees.prefix(2).map { email -> String in
            // Extract name from email if possible
            if let atIndex = email.firstIndex(of: "@") {
                return String(email[..<atIndex]).capitalized
            }
            return email
        }

        if event.attendees.count > 2 {
            return names.joined(separator: ", ") + " +\(event.attendees.count - 2)"
        }
        return names.joined(separator: ", ")
    }
}

#Preview {
    VStack(spacing: 0) {
        CalendarEventRowView(event: CalendarEvent(
            googleEventId: "1",
            calendarId: "primary",
            title: "Standup with Alice",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            attendees: ["alice@example.com", "bob@example.com"]
        ))

        CalendarEventRowView(event: CalendarEvent(
            googleEventId: "2",
            calendarId: "primary",
            title: "Team Sync",
            startTime: Date().addingTimeInterval(3600),
            endTime: Date().addingTimeInterval(5400),
            location: "Google Meet"
        ))

        CalendarEventRowView(event: CalendarEvent(
            googleEventId: "3",
            calendarId: "primary",
            title: "Team Standup",
            startTime: Date(),
            endTime: Date().addingTimeInterval(86400),
            isAllDay: true
        ))
    }
    .frame(width: 400)
    .padding()
    #if os(macOS)
    .background(Theme.Colors.background)
    #else
    .background(Color(uiColor: .systemBackground))
    #endif
}
