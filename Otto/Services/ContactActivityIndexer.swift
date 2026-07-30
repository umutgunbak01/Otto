import Foundation

/// One thing that constitutes "we talked" — drives `lastContactedAt` on both
/// Connections and Network Hub entries, the detail views' touchpoint
/// timelines, and the keep-in-touch follow-up queue.
struct Touchpoint: Identifiable, Hashable {
    enum Kind: String {
        case email
        case meeting     // transcribed/imported Meeting record
        case calendar    // Google Calendar event (no Otto tab to open)
        case dm

        var iconName: String {
            switch self {
            case .email: return "envelope"
            case .meeting: return "waveform"
            case .calendar: return "calendar"
            case .dm: return "message"
            }
        }

        var label: String {
            switch self {
            case .email: return "Email"
            case .meeting: return "Meeting"
            case .calendar: return "Calendar"
            case .dm: return "DM"
            }
        }
    }

    /// Stable across recomputes (derived from the source item) so SwiftUI
    /// lists don't churn and selection survives a refresh.
    let id: String
    let kind: Kind
    let date: Date
    let title: String
    /// Deep-link target when the source is an openable Otto item — emails,
    /// meetings, and X DMs `appState.locate` to their tab; calendar events
    /// render inert (they have no list view).
    let sourceType: ContentType?
    let sourceId: UUID?
}

/// The people an activity source can be attributed to. Built once per person
/// from whichever identifiers that model carries.
struct PersonIdentity {
    /// Normalized (trimmed, lowercased) addresses. Empty when unknown.
    let emails: Set<String>
    /// Normalized full name, "" when unknown. Only used as a fallback when
    /// `emails` is empty — avoids "John Smith" collisions once we *do* have
    /// an address to match on.
    let name: String
    /// Normalized X handles (no "@").
    let xUsernames: Set<String>

    init(emails: [String?], name: String?, xUsernames: [String?] = []) {
        self.emails = Set(emails.compactMap(ContactActivityIndex.normalizeAddress))
        self.name = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        self.xUsernames = Set(xUsernames.compactMap { handle in
            let h = (handle ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "@", with: "")
            return h.isEmpty ? nil : h
        })
    }

    init(connection: Connection, followerUsernameById: [UUID: String]) {
        self.init(
            emails: [connection.email],
            name: connection.fullName,
            xUsernames: [connection.linkedXFollowerId.flatMap { followerUsernameById[$0] }]
        )
    }

    init(entry: NetworkEntry) {
        self.init(
            emails: [entry.email, entry.profile?.email],
            name: entry.name
        )
    }
}

/// Reverse index over every activity source: one pass over emails, calendar
/// events, meetings, and X DMs builds address/name/handle → touchpoint maps;
/// per-person lookups are then dictionary hits instead of full rescans.
/// Rebuild cost is O(items); querying all ~4.5k people is O(people).
struct ContactActivityIndex {
    private var byEmail: [String: [Touchpoint]] = [:]
    private var byName: [String: [Touchpoint]] = [:]
    private var byHandle: [String: [Touchpoint]] = [:]

    // MARK: - Build

    static func build(
        emails: [Email],
        calendarEvents: [CalendarEvent],
        meetings: [Meeting],
        xDMs: [XDirectMessage],
        xFollowers: [XFollower]
    ) -> ContactActivityIndex {
        var index = ContactActivityIndex()

        for email in emails {
            let touchpoint = Touchpoint(
                id: "email:\(email.id.uuidString)",
                kind: .email,
                date: email.receivedDate,
                title: email.subject.isEmpty ? email.preview : email.subject,
                sourceType: .email,
                sourceId: email.id
            )
            var addresses = [email.sender]
            addresses.append(contentsOf: email.recipients)
            for raw in addresses {
                if let address = Self.normalizeAddress(raw) {
                    index.byEmail[address, default: []].append(touchpoint)
                }
            }
            if let senderName = email.senderName {
                let name = senderName.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { index.byName[name, default: []].append(touchpoint) }
            }
        }

        for event in calendarEvents {
            let touchpoint = Touchpoint(
                id: "calendar:\(event.id.uuidString)",
                kind: .calendar,
                date: event.startTime,
                title: event.title,
                sourceType: nil,
                sourceId: nil
            )
            for raw in event.attendees {
                if let address = Self.normalizeAddress(raw) {
                    index.byEmail[address, default: []].append(touchpoint)
                }
            }
        }

        for meeting in meetings {
            let touchpoint = Touchpoint(
                id: "meeting:\(meeting.id.uuidString)",
                kind: .meeting,
                date: meeting.meetingDate,
                title: meeting.title,
                sourceType: .meeting,
                sourceId: meeting.id
            )
            // Participants are emails from Fireflies but display names from
            // Otto-recorded meetings — route by shape. Organizer is an email.
            var routed = meeting.participants
            routed.append(meeting.organizer)
            for raw in routed {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if trimmed.contains("@"), let address = Self.normalizeAddress(trimmed) {
                    index.byEmail[address, default: []].append(touchpoint)
                } else {
                    index.byName[trimmed.lowercased(), default: []].append(touchpoint)
                }
            }
        }

        // DMs: attribute to the counterparty in both directions — sender for
        // inbound, recipient (resolved via the follower userId map) for
        // outbound — so replying to someone counts as touching them.
        let usernameByUserId: [String: String] = xFollowers.reduce(into: [:]) { acc, follower in
            let handle = follower.username.trimmingCharacters(in: .whitespaces).lowercased()
            if !follower.xUserId.isEmpty, !handle.isEmpty { acc[follower.xUserId] = handle }
        }
        for dm in xDMs {
            let counterparts: [String] = [
                dm.senderUsername.trimmingCharacters(in: .whitespaces).lowercased(),
                usernameByUserId[dm.recipientId] ?? ""
            ]
            let touchpoint = Touchpoint(
                id: "dm:\(dm.id.uuidString)",
                kind: .dm,
                date: dm.createdAt,
                title: "DM — " + String(dm.text.prefix(80)),
                sourceType: .xDm,
                sourceId: dm.id
            )
            for handle in counterparts where !handle.isEmpty {
                index.byHandle[handle, default: []].append(touchpoint)
            }
        }

        return index
    }

    // MARK: - Query

    /// All touchpoints for a person, newest first, deduped by source.
    /// `limit` trims after sorting; pass nil for the full history.
    func touchpoints(for identity: PersonIdentity, limit: Int? = nil) -> [Touchpoint] {
        var seen = Set<String>()
        var merged: [Touchpoint] = []

        func add(_ list: [Touchpoint]?) {
            guard let list else { return }
            for touchpoint in list where seen.insert(touchpoint.id).inserted {
                merged.append(touchpoint)
            }
        }

        if identity.emails.isEmpty {
            // Name fallback only when no address is known.
            if !identity.name.isEmpty { add(byName[identity.name]) }
        } else {
            for address in identity.emails { add(byEmail[address]) }
        }
        for handle in identity.xUsernames { add(byHandle[handle]) }

        merged.sort { $0.date > $1.date }
        if let limit { return Array(merged.prefix(limit)) }
        return merged
    }

    /// Most recent contact date, or nil when no activity matches.
    func lastContact(for identity: PersonIdentity) -> Date? {
        touchpoints(for: identity, limit: 1).first?.date
    }

    // MARK: - Normalization

    /// Lowercase a bare address; unwrap "Name <addr@host>" forms; reject
    /// non-addresses. Calendar attendee strings and email recipients both
    /// pass through here so format drift can't break matching.
    static func normalizeAddress(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if let open = s.range(of: "<"), let close = s.range(of: ">"), open.upperBound < close.lowerBound {
            s = String(s[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard s.contains("@"), !s.contains(" ") else { return nil }
        return s
    }
}

/// Stateless recompute entry points, called from AppState at sync boundaries.
enum ContactActivityIndexer {

    /// Returns both people collections with `lastContactedAt` ratcheted
    /// forward where evidence is found. Values never move backwards, so a
    /// manual "mark contacted" or a prior sync's finding survives a sync
    /// that lost evidence.
    static func recompute(
        connections: [Connection],
        networkEntries: [NetworkEntry],
        emails: [Email],
        calendarEvents: [CalendarEvent],
        meetings: [Meeting],
        xDMs: [XDirectMessage],
        xFollowers: [XFollower]
    ) -> (connections: [Connection], networkEntries: [NetworkEntry]) {
        let index = ContactActivityIndex.build(
            emails: emails,
            calendarEvents: calendarEvents,
            meetings: meetings,
            xDMs: xDMs,
            xFollowers: xFollowers
        )
        let followerUsernameById: [UUID: String] = Dictionary(
            uniqueKeysWithValues: xFollowers.map { ($0.id, $0.username.lowercased()) }
        )

        let updatedConnections = connections.map { connection in
            var updated = connection
            let identity = PersonIdentity(connection: connection, followerUsernameById: followerUsernameById)
            if let candidate = index.lastContact(for: identity) {
                updated.lastContactedAt = maxDate(connection.lastContactedAt, candidate)
            }
            return updated
        }

        let updatedEntries = networkEntries.map { entry in
            var updated = entry
            if let candidate = index.lastContact(for: PersonIdentity(entry: entry)) {
                updated.lastContactedAt = maxDate(entry.lastContactedAt, candidate)
            }
            return updated
        }

        return (updatedConnections, updatedEntries)
    }

    /// Top-N recent touchpoints for one connection, newest first — builds a
    /// throwaway index; fine for a detail view, wasteful in a loop (use
    /// `ContactActivityIndex.build` + `touchpoints(for:)` there).
    static func recentTouchpoints(
        for connection: Connection,
        emails: [Email],
        calendarEvents: [CalendarEvent],
        meetings: [Meeting] = [],
        xDMs: [XDirectMessage] = [],
        xFollowers: [XFollower] = [],
        limit: Int = 5
    ) -> [Touchpoint] {
        let index = ContactActivityIndex.build(
            emails: emails,
            calendarEvents: calendarEvents,
            meetings: meetings,
            xDMs: xDMs,
            xFollowers: xFollowers
        )
        let followerUsernameById: [UUID: String] = Dictionary(
            uniqueKeysWithValues: xFollowers.map { ($0.id, $0.username.lowercased()) }
        )
        let identity = PersonIdentity(connection: connection, followerUsernameById: followerUsernameById)
        return index.touchpoints(for: identity, limit: limit)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}
