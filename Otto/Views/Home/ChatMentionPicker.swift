import SwiftUI

// MARK: - Chat @-Mention Tagging
//
// Lets the USER tag items in the composer the same way the agent tags them
// in its answers. Typing `@` opens an autocomplete over every taggable item
// type; picking a result inserts a friendly `@Title` token into the input.
// On send, `OttoChatView` expands each token to the same inline item link
// the agent emits — `[Title](otto://<type>/<id>)` — so the agent receives an
// exact item id (no name-based searching) and the transcript renders the
// tag as a clickable chip.

/// One taggable item offered by the `@` autocomplete.
struct MentionItem: Identifiable, Equatable {
    let itemId: UUID
    let type: ContentType
    /// Chip text — also the `@Title` token inserted into the composer.
    let title: String
    /// Extra context shown dim in the picker row (role · company, date…).
    let subtitle: String?

    /// The same UUID can theoretically exist across two collections, so the
    /// row identity spans type + id.
    var id: String { "\(type.rawValue)-\(itemId.uuidString)" }

    /// The inline item link the agent understands — same syntax it uses in
    /// its own prose. `OttoTools.parseItemURL` is the inverse.
    var markdownLink: String {
        "[\(title)](otto://\(type.ottoSlug)/\(itemId.uuidString))"
    }
}

extension ContentType {
    /// snake_case slug used in `otto://<type>/<id>` item links — the inverse
    /// of `OttoTools.previewContentType`.
    var ottoSlug: String {
        switch self {
        case .networkHub: return "network"
        case .xPost:      return "x_post"
        case .xFollower:  return "x_follower"
        case .xDm:        return "x_dm"
        default:          return rawValue
        }
    }
}

// MARK: - Search

enum MentionSearch {
    static let limit = 8

    /// Title-first fuzzy match across every taggable collection. An empty
    /// query (the user just typed "@") surfaces recently touched items so
    /// the panel is never a dead end. Custom-tab records are excluded —
    /// they don't support otto:// links.
    @MainActor
    static func items(matching rawQuery: String, appState: AppState) -> [MentionItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return recents(appState: appState) }

        // (match strength, type weight, item) — people and companies first
        // among equal-strength matches, then shorter titles.
        var scored: [(score: Int, weight: Int, item: MentionItem)] = []

        func consider(_ item: MentionItem, weight: Int) {
            guard !item.title.isEmpty else { return }
            let title = item.title.lowercased()
            let score: Int
            if title.hasPrefix(query) {
                score = 0
            } else if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
                score = 1
            } else if title.contains(query) {
                score = 2
            } else if let sub = item.subtitle?.lowercased(), sub.contains(query) {
                score = 3
            } else {
                return
            }
            scored.append((score, weight, item))
        }

        for entry in appState.networkEntries { consider(from(entry), weight: 0) }
        for connection in appState.connections { consider(from(connection), weight: 1) }
        for company in appState.companies { consider(from(company), weight: 2) }
        for meeting in appState.meetings { consider(from(meeting), weight: 3) }
        for note in appState.notes { consider(from(note), weight: 4) }
        for todo in appState.todos { consider(from(todo), weight: 5) }
        for event in appState.events { consider(from(event), weight: 6) }
        for community in appState.communities { consider(from(community), weight: 7) }
        for email in appState.emails { consider(from(email), weight: 8) }
        for file in appState.files { consider(from(file), weight: 9) }
        for idea in appState.ideas { consider(from(idea), weight: 10) }
        for reminder in appState.reminders { consider(from(reminder), weight: 11) }
        for bookmark in appState.bookmarks { consider(from(bookmark), weight: 12) }
        for habit in appState.habits { consider(from(habit), weight: 13) }
        for follower in appState.xFollowers { consider(from(follower), weight: 14) }
        for post in appState.xPosts { consider(from(post), weight: 15) }
        for dm in appState.xDirectMessages { consider(from(dm), weight: 16) }

        return scored
            .sorted {
                ($0.score, $0.weight, $0.item.title.count) < ($1.score, $1.weight, $1.item.title.count)
            }
            .prefix(limit)
            .map(\.item)
    }

    /// Bare-"@" suggestions: the most recently touched items across the
    /// collections people actually tag (contacts, meetings, notes, open
    /// todos, companies).
    @MainActor
    private static func recents(appState: AppState) -> [MentionItem] {
        var dated: [(item: MentionItem, date: Date)] = []
        dated += appState.networkEntries.map { (from($0), $0.updatedAt) }
        dated += appState.meetings.map { (from($0), $0.meetingDate) }
        dated += appState.notes.map { (from($0), $0.updatedAt) }
        dated += appState.todos.filter { !$0.isCompleted }.map { (from($0), $0.updatedAt) }
        dated += appState.companies.map { (from($0), $0.updatedAt) }
        return dated
            .filter { !$0.item.title.isEmpty }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.item)
    }

    // MARK: Per-type builders

    private static func from(_ entry: NetworkEntry) -> MentionItem {
        let subtitle = [entry.title, entry.company].filter { !$0.isEmpty }.joined(separator: " · ")
        return MentionItem(
            itemId: entry.id,
            type: .networkHub,
            title: entry.name.isEmpty ? entry.company : entry.name,
            subtitle: subtitle.isEmpty ? nil : subtitle
        )
    }

    private static func from(_ connection: Connection) -> MentionItem {
        MentionItem(
            itemId: connection.id,
            type: .connection,
            title: connection.fullName,
            subtitle: connection.headline.isEmpty ? nil : connection.headline
        )
    }

    private static func from(_ company: Company) -> MentionItem {
        MentionItem(
            itemId: company.id,
            type: .company,
            title: company.name,
            subtitle: company.location.isEmpty ? nil : company.location
        )
    }

    private static func from(_ meeting: Meeting) -> MentionItem {
        MentionItem(
            itemId: meeting.id,
            type: .meeting,
            title: meeting.title,
            subtitle: meeting.meetingDate.formatted(date: .abbreviated, time: .omitted)
        )
    }

    private static func from(_ note: Note) -> MentionItem {
        MentionItem(
            itemId: note.id,
            type: .note,
            title: note.title,
            subtitle: note.updatedAt.formatted(date: .abbreviated, time: .omitted)
        )
    }

    private static func from(_ todo: Todo) -> MentionItem {
        MentionItem(
            itemId: todo.id,
            type: .todo,
            title: todo.title,
            subtitle: todo.dueDate.map { "due \($0.formatted(date: .abbreviated, time: .omitted))" }
        )
    }

    private static func from(_ event: Event) -> MentionItem {
        MentionItem(
            itemId: event.id,
            type: .event,
            title: event.name,
            subtitle: event.location.isEmpty ? nil : event.location
        )
    }

    private static func from(_ community: Community) -> MentionItem {
        MentionItem(
            itemId: community.id,
            type: .community,
            title: community.name,
            subtitle: community.location.isEmpty ? nil : community.location
        )
    }

    private static func from(_ email: Email) -> MentionItem {
        MentionItem(
            itemId: email.id,
            type: .email,
            title: email.subject,
            subtitle: email.senderName ?? email.sender
        )
    }

    private static func from(_ file: FileItem) -> MentionItem {
        MentionItem(
            itemId: file.id,
            type: .file,
            title: file.name,
            subtitle: file.fileType.displayName
        )
    }

    private static func from(_ idea: Idea) -> MentionItem {
        MentionItem(itemId: idea.id, type: .idea, title: idea.title, subtitle: nil)
    }

    private static func from(_ reminder: Reminder) -> MentionItem {
        MentionItem(itemId: reminder.id, type: .reminder, title: reminder.title, subtitle: nil)
    }

    private static func from(_ bookmark: Bookmark) -> MentionItem {
        MentionItem(
            itemId: bookmark.id,
            type: .bookmark,
            title: bookmark.title,
            subtitle: bookmark.url.isEmpty ? nil : bookmark.url
        )
    }

    private static func from(_ habit: Habit) -> MentionItem {
        MentionItem(itemId: habit.id, type: .habit, title: habit.title, subtitle: nil)
    }

    private static func from(_ follower: XFollower) -> MentionItem {
        MentionItem(
            itemId: follower.id,
            type: .xFollower,
            title: follower.displayName.isEmpty ? follower.username : follower.displayName,
            subtitle: "@\(follower.username)"
        )
    }

    private static func from(_ post: XPost) -> MentionItem {
        MentionItem(
            itemId: post.id,
            type: .xPost,
            title: post.authorUsername.isEmpty ? "X post" : "\(post.authorUsername) post",
            subtitle: oneLine(post.text)
        )
    }

    private static func from(_ dm: XDirectMessage) -> MentionItem {
        MentionItem(
            itemId: dm.id,
            type: .xDm,
            title: dm.senderDisplayName.isEmpty ? dm.senderUsername : dm.senderDisplayName,
            subtitle: oneLine(dm.text)
        )
    }

    private static func oneLine(_ raw: String, max: Int = 60) -> String? {
        let flat = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return nil }
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}

// MARK: - Suggestion Panel

/// The autocomplete panel shown above the composer while an `@token` is
/// active. Keyboard driven from the TextField (↑↓ move, ↩/⇥ tag, esc
/// dismiss); rows also respond to hover + click. Results are capped at
/// `MentionSearch.limit`, so a plain VStack is fine — no scrolling needed.
struct MentionSuggestionList: View {
    let results: [MentionItem]
    @Binding var selectedIndex: Int
    let onPick: (MentionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "at")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Tag an item")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer(minLength: 0)
                Text("↑↓ · ↩ tag · esc")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                row(item, isSelected: index == selectedIndex)
                    .onTapGesture { onPick(item) }
                    .onHover { hovering in
                        if hovering { selectedIndex = index }
                    }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.borderStrong, lineWidth: 1)
        )
    }

    private func row(_ item: MentionItem, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(item.type.color.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: item.type.iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.type.color)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            Text(item.type.displayName.lowercased())
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
