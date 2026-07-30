import Foundation

/// Opt-in email triage (Settings → Interface). When enabled, Otto computes a
/// "needs reply" queue from already-synced Gmail data — no new scopes, no
/// network calls:
///
///   A thread needs a reply when its latest message is inbound (not yours),
///   recent, person-to-person (not a newsletter / notification / category
///   mail), and nothing you sent comes after it. Your own address is inferred
///   from SENT mail, so there's nothing to configure.
///
/// Everything here is pure computation over AppState arrays; the queue is
/// recomputed on render (a single pass over emails — cheap next to the
/// LazyVStack it feeds).
enum EmailTriageSettings {
    static let enabledKey = "email.triage.enabled"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum EmailTriageService {

    /// How far back the queue looks. Older unanswered mail is stale enough
    /// that surfacing it does more harm than good.
    static let windowDays = 21

    /// The user's own address(es), inferred from the senders of SENT mail.
    /// (Gmail sync stores sent messages alongside inbox mail; the Gmail
    /// layer itself never learns the profile address.)
    static func selfAddresses(in emails: [Email]) -> Set<String> {
        var addresses = Set<String>()
        for email in emails where email.labels.contains("SENT") {
            if let address = ContactActivityIndex.normalizeAddress(email.sender) {
                addresses.insert(address)
            }
        }
        return addresses
    }

    /// Sender patterns that never warrant a reply.
    private static let automatedSenderMarkers: [String] = [
        "no-reply", "noreply", "do-not-reply", "donotreply", "notifications@",
        "notification@", "mailer-daemon", "postmaster@", "newsletter@", "digest@"
    ]

    /// Gmail category labels that mark bulk mail.
    private static let bulkLabels: Set<String> = [
        "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS", "CATEGORY_UPDATES", "SPAM"
    ]

    /// The needs-reply queue, newest first: latest inbound message of every
    /// thread the user hasn't answered (or dismissed).
    static func needsReply(
        emails: [Email],
        blockedSenders: [String] = [],
        now: Date = Date()
    ) -> [Email] {
        guard !emails.isEmpty else { return [] }
        let selfAddrs = selfAddresses(in: emails)
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? now
        let blocked = Set(blockedSenders.map { $0.lowercased() })

        // Latest SENT date per thread — "did I answer after that?" evidence.
        var latestSentByThread: [String: Date] = [:]
        for email in emails where email.labels.contains("SENT") || isFromSelf(email, selfAddrs: selfAddrs) {
            latestSentByThread[email.threadId] = max(latestSentByThread[email.threadId] ?? .distantPast, email.receivedDate)
        }

        // Latest inbound candidate per thread.
        var candidateByThread: [String: Email] = [:]
        for email in emails {
            guard !email.labels.contains("DRAFT") else { continue }
            guard !email.labels.contains("SENT"), !isFromSelf(email, selfAddrs: selfAddrs) else { continue }
            guard email.receivedDate >= cutoff else { continue }
            guard !isAutomated(email) else { continue }
            guard !blocked.contains(where: { email.sender.lowercased().contains($0) }) else { continue }
            if let existing = candidateByThread[email.threadId], existing.receivedDate >= email.receivedDate {
                continue
            }
            candidateByThread[email.threadId] = email
        }

        return candidateByThread.values
            .filter { candidate in
                // Unanswered: nothing sent in this thread after the candidate.
                if let sent = latestSentByThread[candidate.threadId], sent >= candidate.receivedDate {
                    return false
                }
                return candidate.needsReplyDismissedAt == nil
            }
            .sorted { $0.receivedDate > $1.receivedDate }
    }

    /// Cheap count for badges; same predicate as `needsReply`.
    static func needsReplyCount(emails: [Email], blockedSenders: [String] = []) -> Int {
        needsReply(emails: emails, blockedSenders: blockedSenders).count
    }

    static func isFromSelf(_ email: Email, selfAddrs: Set<String>) -> Bool {
        guard let sender = ContactActivityIndex.normalizeAddress(email.sender) else { return false }
        return selfAddrs.contains(sender)
    }

    static func isAutomated(_ email: Email) -> Bool {
        if email.labels.contains(where: { bulkLabels.contains($0) }) { return true }
        let sender = email.sender.lowercased()
        if automatedSenderMarkers.contains(where: { sender.contains($0) }) { return true }
        // Unsubscribe framing in the body tail is a strong bulk signal.
        let tail = String(email.body.suffix(600)).lowercased()
        if tail.contains("unsubscribe") || tail.contains("abonelikten çık") { return true }
        return false
    }

    /// Web deep link to the thread (Gmail accepts the API's hex thread id).
    static func gmailThreadURL(for email: Email) -> URL? {
        URL(string: "https://mail.google.com/mail/u/0/#all/\(email.threadId)")
    }
}
