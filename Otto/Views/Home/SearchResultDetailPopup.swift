import SwiftUI

struct SearchResultDetailPopup: View {
    @Environment(AppState.self) private var appState
    let result: UniversalSearchResult
    var onClose: (() -> Void)?
    var onLocate: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            OttoDivider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    detailContent
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .frame(width: 550, height: 500)
        .background(Theme.Colors.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Content type icon
            Image(systemName: result.contentType.iconName)
                .font(.system(size: 16))
                .foregroundStyle(result.contentType.color)
                .frame(width: 32, height: 32)
                .background(result.contentType.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.contentType.displayName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                Text(result.title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
            }

            Spacer()

            // Locate button
            Button {
                onLocate?()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                    Text("Locate")
                }
                .font(Theme.Typography.caption)
            }
            .buttonStyle(GhostButtonStyle())
            #if os(macOS)
            .help("Navigate to this item in its category")
            #endif

            // Close button
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Theme.Colors.borderSubtle)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch result.contentType {
        case .todo:
            if let todo = result.todo {
                todoDetail(todo)
            }
        case .note:
            if let note = result.note {
                noteDetail(note)
            }
        case .idea:
            if let idea = result.idea {
                ideaDetail(idea)
            }
        case .reminder:
            if let reminder = result.reminder {
                reminderDetail(reminder)
            }
        case .bookmark:
            if let bookmark = result.bookmark {
                bookmarkDetail(bookmark)
            }
        case .meeting:
            if let meeting = result.meeting {
                meetingDetail(meeting)
            }
        case .email:
            if let email = result.email {
                emailDetail(email)
            }
        case .connection:
            if let connection = result.connection {
                connectionDetail(connection)
            }
        case .file:
            if let file = result.file {
                fileDetail(file)
            }
        case .xPost:
            if let post = result.xPost {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("@\(post.authorUsername)")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(ContentType.xPost.color)
                    Text(post.text)
                        .font(Theme.Typography.body)
                        .lineLimit(10)
                    HStack(spacing: Theme.Spacing.lg) {
                        Label("\(post.likeCount)", systemImage: "heart")
                        Label("\(post.retweetCount)", systemImage: "arrow.2.squarepath")
                        Label("\(post.replyCount)", systemImage: "bubble.right")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        case .xFollower:
            if let follower = result.xFollower {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("@\(follower.username)")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(ContentType.xFollower.color)
                    if !follower.bio.isEmpty {
                        Text(follower.bio)
                            .font(Theme.Typography.body)
                            .lineLimit(5)
                    }
                    HStack(spacing: Theme.Spacing.lg) {
                        Text("\(follower.followersCount) followers")
                        Text("\(follower.followingCount) following")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        case .habit:
            // Habit detail isn't surfaced through the chat preview popup —
            // the user opens habits from the Habits tab.
            EmptyView()
        case .xDm:
            if let dm = result.xDirectMessage {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("@\(dm.senderUsername)")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(ContentType.xDm.color)
                    Text(dm.text)
                        .font(Theme.Typography.body)
                        .lineLimit(10)
                }
            }
        }

        // Calendar event (shown as todo content type)
        if let event = result.calendarEvent {
            calendarEventDetail(event)
        }
    }

    // MARK: - Todo Detail

    private func todoDetail(_ todo: Todo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Status
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(todo.isCompleted ? "Completed" : "Active", color: todo.isCompleted ? .green : .blue)

                if let dueDate = todo.dueDate {
                    Label(formatDate(dueDate), systemImage: "calendar")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                priorityBadge(todo.priority)
            }

            // Description
            if !todo.description.isEmpty {
                detailSection("Description") {
                    Text(todo.description)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            metadataSection(created: todo.createdAt, updated: todo.updatedAt)
        }
    }

    // MARK: - Note Detail

    private func noteDetail(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Category
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(note.primaryCategory.rawValue, color: categoryColor(note.primaryCategory))
            }

            // Content
            if !note.content.isEmpty {
                detailSection("Content") {
                    Text(note.content)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            metadataSection(created: note.createdAt, updated: note.updatedAt)
        }
    }

    // MARK: - Idea Detail

    private func ideaDetail(_ idea: Idea) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Status & Category
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(idea.status.rawValue, color: ideaStatusColor(idea.status))
                statusBadge(idea.primaryCategory.rawValue, color: categoryColor(idea.primaryCategory))
            }

            // Content
            if !idea.content.isEmpty {
                detailSection("Content") {
                    Text(idea.content)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Research Prompt
            if !idea.researchPrompt.isEmpty {
                detailSection("Research Prompt") {
                    Text(idea.researchPrompt)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            metadataSection(created: idea.createdAt, updated: idea.updatedAt)
        }
    }

    // MARK: - Reminder Detail

    private func reminderDetail(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Status & Date
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(reminder.isTriggered ? "Triggered" : "Pending", color: reminder.isTriggered ? Theme.Colors.textDim : Theme.Colors.amber)

                Label(formatDateTime(reminder.reminderDate), systemImage: "bell")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Created date only (Reminder doesn't have updatedAt)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                OttoDivider()
                    .padding(.vertical, Theme.Spacing.sm)

                Label("Created: \(formatDate(reminder.createdAt))", systemImage: "plus.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    // MARK: - Bookmark Detail

    private func bookmarkDetail(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Status & Type
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(bookmark.isRead ? "Read" : "Unread", color: bookmark.isRead ? .gray : .pink)
                statusBadge(bookmark.mediaType.rawValue, color: .purple)
            }

            // URL
            detailSection("URL") {
                Link(bookmark.url, destination: URL(string: bookmark.url) ?? URL(string: "about:blank")!)
                    .font(Theme.Typography.body)
            }

            // Description
            if !bookmark.description.isEmpty {
                detailSection("Description") {
                    Text(bookmark.description)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            metadataSection(created: bookmark.createdAt, updated: bookmark.updatedAt)
        }
    }

    // MARK: - Meeting Detail

    private func meetingDetail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Date & Duration
            HStack(spacing: Theme.Spacing.md) {
                Label(formatDateTime(meeting.meetingDate), systemImage: "calendar")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                if meeting.duration > 0 {
                    Label(formatDuration(meeting.duration), systemImage: "clock")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Participants
            if !meeting.participants.isEmpty {
                detailSection("Participants") {
                    Text(meeting.participants.joined(separator: ", "))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Overview
            if !meeting.overview.isEmpty {
                detailSection("Overview") {
                    Text(meeting.overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Action Items
            if !meeting.actionItems.isEmpty {
                detailSection("Action Items") {
                    Text(meeting.actionItems)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            metadataSection(created: meeting.createdAt, updated: meeting.updatedAt)
        }
    }

    // MARK: - Email Detail

    private func emailDetail(_ email: Email) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Status & Sender
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(email.isRead ? "Read" : "Unread", color: email.isRead ? .gray : .cyan)
            }

            // From
            detailSection("From") {
                Text(email.displaySender)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
            }

            // Date
            detailSection("Received") {
                Text(formatDateTime(email.receivedDate))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Body
            if !email.body.isEmpty {
                detailSection("Message") {
                    Text(email.body)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }
        }
    }

    // MARK: - Connection Detail

    private func connectionDetail(_ connection: Connection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Headline & Company
            HStack(spacing: Theme.Spacing.md) {
                if !connection.headline.isEmpty {
                    statusBadge(connection.headline, color: .indigo)
                }
                if !connection.company.isEmpty {
                    statusBadge(connection.company, color: .teal)
                }
            }

            // Location
            if !connection.location.isEmpty {
                detailSection("Location") {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "mappin")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(connection.location)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                    }
                }
            }

            // Contact Info
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let email = connection.email {
                    detailSection("Email") {
                        HStack {
                            Text(email)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.text)
                            Spacer()
                            Button {
                                if let url = URL(string: "mailto:\(email)") {
                                    openURL(url)
                                }
                            } label: {
                                Text("Send")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let profileUrl = connection.profileUrl {
                    detailSection("LinkedIn") {
                        HStack {
                            Text("Profile")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.text)
                            Spacer()
                            Button {
                                if let url = URL(string: profileUrl) {
                                    openURL(url)
                                }
                            } label: {
                                Text("Open")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Tags
            if !connection.tags.isEmpty {
                detailSection("Tags") {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        ForEach(connection.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.connection.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(ContentType.connection.color.opacity(0.1))
                                )
                        }
                    }
                }
            }

            // Notes
            if !connection.notes.isEmpty {
                detailSection("Notes") {
                    Text(connection.notes)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Connection date
            if let connectionDate = connection.connectionDate {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    OttoDivider()
                        .padding(.vertical, Theme.Spacing.sm)

                    Label("Connected: \(formatDate(connectionDate))", systemImage: "person.badge.plus")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        }
    }

    // MARK: - File Detail

    private func fileDetail(_ file: FileItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Type & Size
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(file.fileType.displayName, color: fileTypeColor(file.fileType))
                statusBadge(file.formattedSize, color: .gray)
            }

            // File Info
            detailSection("File") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        Text("Extension:")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(".\(file.fileExtension)")
                            .font(Theme.Typography.body)
                    }
                }
            }

            // Tags
            if !file.tags.isEmpty {
                detailSection("Tags") {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        ForEach(file.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.file.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(ContentType.file.color.opacity(0.1))
                                )
                        }
                    }
                }
            }

            // Notes
            if !file.notes.isEmpty {
                detailSection("Notes") {
                    Text(file.notes)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Extracted text preview
            if let extractedText = file.extractedText, !extractedText.isEmpty {
                detailSection("Content Preview") {
                    Text(String(extractedText.prefix(500)))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(10)
                }
            }

            metadataSection(created: file.createdAt, updated: file.updatedAt)
        }
    }

    private func fileTypeColor(_ type: FileType) -> Color {
        switch type {
        case .csv, .excel: return .green
        case .image: return .blue
        case .pdf: return .red
        case .text: return .secondary
        case .video: return .purple
        case .audio: return .orange
        }
    }

    // MARK: - Calendar Event Detail

    private func calendarEventDetail(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Time
            HStack(spacing: Theme.Spacing.md) {
                statusBadge(event.isPast ? "Past" : "Upcoming", color: event.isPast ? .gray : .teal)

                Label(event.formattedTimeRange, systemImage: "clock")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            // Location
            if let location = event.location, !location.isEmpty {
                detailSection("Location") {
                    Text(location)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Description
            if let description = event.description, !description.isEmpty {
                detailSection("Description") {
                    Text(description)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Attendees
            if !event.attendees.isEmpty {
                detailSection("Attendees") {
                    Text(event.attendees.joined(separator: ", "))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }

            // Open in Google Calendar
            if let htmlLink = event.htmlLink, let url = URL(string: htmlLink) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                        .font(Theme.Typography.body)
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    // MARK: - Helper Views

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .textCase(.uppercase)

            content()
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private func priorityBadge(_ priority: Todo.Priority) -> some View {
        HStack(spacing: 2) {
            Image(systemName: priority.iconName)
                .font(.system(size: 10))
            Text(priority.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(priorityColor(priority))
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 3)
        .background(priorityColor(priority).opacity(0.1))
        .clipShape(Capsule())
    }

    private func metadataSection(created: Date, updated: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            OttoDivider()
                .padding(.vertical, Theme.Spacing.sm)

            HStack(spacing: Theme.Spacing.lg) {
                Label("Created: \(formatDate(created))", systemImage: "plus.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Label("Updated: \(formatDate(updated))", systemImage: "pencil.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }

    private func priorityColor(_ priority: Todo.Priority) -> Color {
        switch priority {
        case .urgent: return Theme.Colors.priorityUrgent
        case .high: return Theme.Colors.priorityHigh
        case .medium: return Theme.Colors.priorityMedium
        case .low: return Theme.Colors.priorityLow
        }
    }

    private func categoryColor(_ category: PrimaryCategory) -> Color {
        switch category {
        case .work: return Theme.Colors.work
        case .personal: return Theme.Colors.personal
        case .hobby: return Theme.Colors.hobby
        }
    }

    private func ideaStatusColor(_ status: Idea.Status) -> Color {
        switch status {
        case .raw: return .gray
        case .researched: return .blue
        case .validated: return .green
        case .archived: return .gray
        }
    }
}

#Preview {
    SearchResultDetailPopup(
        result: UniversalSearchResult(
            id: UUID(),
            contentType: .todo,
            title: "Review project proposal for Q1",
            subtitle: "Due Tomorrow",
            snippet: "Need to review the quarterly proposal and provide feedback",
            date: Date(),
            isArchived: false,
            todo: Todo(
                title: "Review project proposal for Q1",
                description: "Need to review the quarterly proposal and provide feedback to the team before the deadline.",
                dueDate: Date().addingTimeInterval(86400),
                priority: .high
            )
        ),
        onClose: {},
        onLocate: {}
    )
    .environment(AppState())
}
