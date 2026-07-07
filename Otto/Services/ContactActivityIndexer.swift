import Foundation

/// One thing that constitutes "we talked" — used both to compute
/// `Connection.lastContactedAt` and to drive the detail-view's
/// "Recent touchpoints" list.
struct Touchpoint: Identifiable, Hashable {
    enum Kind: String {
        case email
        case meeting
        case dm
    }

    let id: UUID = UUID()
    let kind: Kind
    let date: Date
    let title: String
}

/// Stateless helpers that scan the existing email / calendar / X data
/// and surface a single most-recent contact date per connection.
///
/// Matching rules (in order):
///   1. Strict: `connection.email` (case-insensitive, trimmed) appears as a
///      Gmail `sender`, in `Email.recipients`, or in `CalendarEvent.attendees`.
///   2. Fallback: `connection.fullName` (case-insensitive, trimmed) appears
///      as an `Email.senderName`. (Calendar attendees are emails only, so the
///      name fallback doesn't apply there.)
///   3. X DMs use the existing `linkedXFollowerId` link — no fuzziness.
///
/// Recomputation is O(connections × emails) worst case, but is bounded by
/// sync boundaries (Gmail / Calendar / X), not by render cycles.
enum ContactActivityIndexer {

    /// Returns `connections` with `lastContactedAt` updated where evidence
    /// is found. Connections with no matches keep their existing value
    /// (so a one-off manual entry isn't wiped by a sync that found nothing).
    static func recompute(
        connections: [Connection],
        emails: [Email],
        calendarEvents: [CalendarEvent],
        xDMs: [XDirectMessage],
        xFollowers: [XFollower]
    ) -> [Connection] {
        // Build the X follower → username map up front so the DM scan is O(1)
        // per message instead of O(followers) per message.
        let followerUsernameById: [UUID: String] = Dictionary(
            uniqueKeysWithValues: xFollowers.map { ($0.id, $0.username.lowercased()) }
        )

        return connections.map { connection in
            var updated = connection
            let candidate = latestContact(
                for: connection,
                emails: emails,
                calendarEvents: calendarEvents,
                xDMs: xDMs,
                followerUsernameById: followerUsernameById
            )
            if let candidate = candidate {
                // Don't ratchet backwards on a sync that lost evidence.
                if let existing = connection.lastContactedAt {
                    updated.lastContactedAt = max(existing, candidate)
                } else {
                    updated.lastContactedAt = candidate
                }
            }
            return updated
        }
    }

    /// Top-N recent touchpoints for one connection, newest first.
    /// Used by the detail view; the table doesn't need this.
    static func recentTouchpoints(
        for connection: Connection,
        emails: [Email],
        calendarEvents: [CalendarEvent],
        limit: Int = 5
    ) -> [Touchpoint] {
        let normalizedEmail = connection.email?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let normalizedName = connection.fullName.trimmingCharacters(in: .whitespaces).lowercased()

        var touchpoints: [Touchpoint] = []

        for email in emails {
            if matches(email: email, connectionEmail: normalizedEmail, connectionName: normalizedName) {
                touchpoints.append(Touchpoint(
                    kind: .email,
                    date: email.receivedDate,
                    title: email.subject.isEmpty ? email.preview : email.subject
                ))
            }
        }

        if !normalizedEmail.isEmpty {
            for event in calendarEvents where event.attendees.contains(where: { $0.lowercased() == normalizedEmail }) {
                touchpoints.append(Touchpoint(
                    kind: .meeting,
                    date: event.startTime,
                    title: event.title
                ))
            }
        }

        return touchpoints
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Internals

    private static func latestContact(
        for connection: Connection,
        emails: [Email],
        calendarEvents: [CalendarEvent],
        xDMs: [XDirectMessage],
        followerUsernameById: [UUID: String]
    ) -> Date? {
        let normalizedEmail = connection.email?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let normalizedName = connection.fullName.trimmingCharacters(in: .whitespaces).lowercased()

        var best: Date? = nil

        for email in emails {
            if matches(email: email, connectionEmail: normalizedEmail, connectionName: normalizedName) {
                best = max(best, email.receivedDate)
            }
        }

        if !normalizedEmail.isEmpty {
            for event in calendarEvents {
                if event.attendees.contains(where: { $0.lowercased() == normalizedEmail }) {
                    best = max(best, event.startTime)
                }
            }
        }

        // X DMs — only via the explicit follower link; no fuzzy username match.
        if let followerId = connection.linkedXFollowerId,
           let username = followerUsernameById[followerId], !username.isEmpty {
            for dm in xDMs where dm.senderUsername.lowercased() == username {
                best = max(best, dm.createdAt)
            }
        }

        return best
    }

    private static func matches(email: Email, connectionEmail: String, connectionName: String) -> Bool {
        if !connectionEmail.isEmpty {
            if email.sender.lowercased().contains(connectionEmail) { return true }
            if email.recipients.contains(where: { $0.lowercased().contains(connectionEmail) }) { return true }
        }
        // Name fallback — only checked when no email is set on the connection.
        // Avoids "John Smith" collisions whenever we *do* have an email.
        if connectionEmail.isEmpty,
           !connectionName.isEmpty,
           let senderName = email.senderName,
           senderName.trimmingCharacters(in: .whitespaces).lowercased() == connectionName {
            return true
        }
        return false
    }
}

private func max(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs = lhs else { return rhs }
    return lhs > rhs ? lhs : rhs
}
