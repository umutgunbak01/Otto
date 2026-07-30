import Testing
import Foundation
@testable import Otto

/// Pure-logic coverage for the relationship batch: contact-activity
/// matching, keep-in-touch due math, the email needs-reply heuristic, and
/// the semantic chunker. No AppState, no disk, no model calls.
struct RelationshipFeatureTests {

    // MARK: - Address normalization

    @Test func normalizeAddressHandlesBareAndBracketedForms() {
        #expect(ContactActivityIndex.normalizeAddress("Ali@Fal.AI ") == "ali@fal.ai")
        #expect(ContactActivityIndex.normalizeAddress("Ali Veli <ali@fal.ai>") == "ali@fal.ai")
        #expect(ContactActivityIndex.normalizeAddress("no-at-sign") == nil)
        #expect(ContactActivityIndex.normalizeAddress("  ") == nil)
        #expect(ContactActivityIndex.normalizeAddress(nil) == nil)
    }

    // MARK: - Touchpoint matching

    private func email(
        from sender: String,
        senderName: String? = nil,
        to recipients: [String] = [],
        subject: String = "Hello",
        daysAgo: Int,
        labels: [String] = []
    ) -> Email {
        Email(
            gmailId: UUID().uuidString,
            threadId: UUID().uuidString,
            subject: subject,
            sender: sender,
            senderName: senderName,
            recipients: recipients,
            body: "body",
            receivedDate: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
            labels: labels,
            snippet: "snippet"
        )
    }

    @Test func indexMatchesPersonByEmailBothDirections() {
        let index = ContactActivityIndex.build(
            emails: [
                email(from: "kaan@acme.com", daysAgo: 10),
                email(from: "me@fal.ai", to: ["Kaan <kaan@acme.com>"], daysAgo: 2, labels: ["SENT"])
            ],
            calendarEvents: [], meetings: [], xDMs: [], xFollowers: []
        )
        let identity = PersonIdentity(emails: ["kaan@acme.com"], name: "Kaan")
        let touchpoints = index.touchpoints(for: identity)
        #expect(touchpoints.count == 2)
        // Newest first — the outbound reply is the latest touch.
        #expect(Calendar.current.dateComponents([.day], from: touchpoints[0].date, to: Date()).day == 2)
    }

    @Test func nameFallbackOnlyAppliesWithoutEmail() {
        let emails = [email(from: "john@corp.com", senderName: "John Smith", daysAgo: 3)]
        let index = ContactActivityIndex.build(
            emails: emails, calendarEvents: [], meetings: [], xDMs: [], xFollowers: []
        )
        // No email on file → name fallback finds the touchpoint.
        let nameOnly = PersonIdentity(emails: [], name: "John Smith")
        #expect(index.touchpoints(for: nameOnly).count == 1)
        // Email on file that doesn't match → the name must NOT be consulted.
        let differentAddress = PersonIdentity(emails: ["john@other.com"], name: "John Smith")
        #expect(index.touchpoints(for: differentAddress).isEmpty)
    }

    @Test func meetingParticipantsMatchByEmailOrDisplayName() {
        let meeting = Meeting(
            title: "Roadmap sync",
            content: "",
            overview: "",
            actionItems: "",
            participants: ["ayse@fal.ai", "Deniz Kaya"],
            organizer: "me@fal.ai",
            duration: 1800,
            meetingDate: Date().addingTimeInterval(-86_400)
        )
        let index = ContactActivityIndex.build(
            emails: [], calendarEvents: [], meetings: [meeting], xDMs: [], xFollowers: []
        )
        #expect(index.touchpoints(for: PersonIdentity(emails: ["ayse@fal.ai"], name: "")).count == 1)
        #expect(index.touchpoints(for: PersonIdentity(emails: [], name: "Deniz Kaya")).count == 1)
        let touchpoint = index.touchpoints(for: PersonIdentity(emails: ["ayse@fal.ai"], name: "")).first
        #expect(touchpoint?.kind == .meeting)
        #expect(touchpoint?.sourceType == .meeting)
    }

    // MARK: - Keep-in-touch due math

    @Test func followUpOverdueDaysComputesFromLastContact() throws {
        var entry = NetworkEntry(name: "Test Person")
        entry.followUpCadence = .monthly
        entry.lastContactedAt = Calendar.current.date(byAdding: .day, value: -45, to: Date())
        // 45 days since contact, monthly (30d) cadence → ~15 days overdue.
        let overdue = try #require(entry.followUpOverdueDays())
        #expect((14...16).contains(overdue))
    }

    @Test func followUpNotDueYetReturnsNil() {
        var entry = NetworkEntry(name: "Test Person")
        entry.followUpCadence = .quarterly
        entry.lastContactedAt = Calendar.current.date(byAdding: .day, value: -10, to: Date())
        #expect(entry.followUpOverdueDays() == nil)
    }

    @Test func snoozeSuppressesDueState() {
        var entry = NetworkEntry(name: "Test Person")
        entry.followUpCadence = .weekly
        entry.lastContactedAt = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        #expect(entry.followUpOverdueDays() != nil)
        entry.followUpSnoozedUntil = Calendar.current.date(byAdding: .day, value: 3, to: Date())
        #expect(entry.followUpOverdueDays() == nil)
    }

    @Test func noCadenceMeansNeverDue() {
        var entry = NetworkEntry(name: "Test Person")
        entry.lastContactedAt = Calendar.current.date(byAdding: .day, value: -400, to: Date())
        #expect(entry.followUpOverdueDays() == nil)
    }

    @Test func networkEntryRoundTripsNewFields() throws {
        var entry = NetworkEntry(name: "Cadence Person")
        entry.followUpCadence = .quarterly
        entry.lastContactedAt = Date(timeIntervalSince1970: 1_700_000_000)
        entry.aiSummary = "A summary"
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(NetworkEntry.self, from: data)
        #expect(decoded.followUpCadence == .quarterly)
        #expect(decoded.aiSummary == "A summary")
        #expect(decoded.lastContactedAt == entry.lastContactedAt)

        // Old JSON without the new keys must still decode (lenient path).
        let legacy = """
        {"id":"\(UUID().uuidString)","type":"startup","company":"Acme","industry":"",
         "name":"Old Row","individualType":"founder","title":"","location":"","email":"",
         "closeness":"unknown","notes":""}
        """
        let old = try JSONDecoder().decode(NetworkEntry.self, from: Data(legacy.utf8))
        #expect(old.followUpCadence == nil)
        #expect(old.name == "Old Row")
    }

    // MARK: - Needs-reply heuristic

    @Test func needsReplyFlagsUnansweredInboundThread() {
        let thread = "thread-1"
        var inbound = email(from: "vc@fund.com", subject: "Term sheet question", daysAgo: 2)
        inbound = withThread(inbound, thread)
        let sent = withThread(email(from: "me@fal.ai", daysAgo: 5, labels: ["SENT"]), thread)
        let queue = EmailTriageService.needsReply(emails: [inbound, sent])
        #expect(queue.count == 1)
        #expect(queue.first?.subject == "Term sheet question")
    }

    @Test func needsReplyClearsWhenUserRepliedAfter() {
        let thread = "thread-2"
        let inbound = withThread(email(from: "vc@fund.com", daysAgo: 4), thread)
        let reply = withThread(email(from: "me@fal.ai", daysAgo: 1, labels: ["SENT"]), thread)
        #expect(EmailTriageService.needsReply(emails: [inbound, reply]).isEmpty)
    }

    @Test func needsReplySkipsBulkAndAutomatedSenders() {
        let promo = email(from: "deals@shop.com", daysAgo: 1, labels: ["CATEGORY_PROMOTIONS"])
        let noreply = email(from: "no-reply@service.com", daysAgo: 1)
        var newsletter = email(from: "team@startup.com", daysAgo: 1)
        newsletter.body = String(repeating: "content ", count: 40) + "Click here to unsubscribe."
        #expect(EmailTriageService.needsReply(emails: [promo, noreply, newsletter]).isEmpty)
    }

    @Test func needsReplyIgnoresOldAndDismissedThreads() {
        let stale = email(from: "old@corp.com", daysAgo: 40)
        var dismissed = email(from: "friend@mail.com", daysAgo: 2)
        dismissed.needsReplyDismissedAt = Date()
        #expect(EmailTriageService.needsReply(emails: [stale, dismissed]).isEmpty)
    }

    @Test func selfAddressInferredFromSentMail() {
        let sent = email(from: "Me <me@fal.ai>", daysAgo: 3, labels: ["SENT"])
        let addrs = EmailTriageService.selfAddresses(in: [sent, email(from: "x@y.com", daysAgo: 1)])
        #expect(addrs == ["me@fal.ai"])
    }

    private func withThread(_ email: Email, _ thread: String) -> Email {
        Email(
            id: email.id, gmailId: email.gmailId, threadId: thread, subject: email.subject,
            sender: email.sender, senderName: email.senderName, recipients: email.recipients,
            body: email.body, receivedDate: email.receivedDate, isRead: email.isRead,
            labels: email.labels, snippet: email.snippet, importedAt: email.importedAt
        )
    }

    // MARK: - Semantic chunker

    @Test func chunkerReturnsWholeShortText() {
        let chunks = SemanticIndexService.chunk("A short note about pricing.", cap: 5)
        #expect(chunks == ["A short note about pricing."])
    }

    @Test func chunkerSplitsLongTextOnSentencesWithinTarget() {
        let sentence = "This is a reasonably long sentence about the quarterly planning cycle. "
        let text = String(repeating: sentence, count: 60) // ~4,300 chars
        let chunks = SemanticIndexService.chunk(text, cap: 40)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.count <= 1_000 })
        // No content dropped below the cap: total length ≈ input length.
        let total = chunks.reduce(0) { $0 + $1.count }
        #expect(total > text.count / 2)
    }

    @Test func chunkerHonorsCap() {
        let text = String(repeating: "Sentence one here. ", count: 500)
        #expect(SemanticIndexService.chunk(text, cap: 4).count <= 4)
    }

    @Test func normalizeStripsMarkdownChrome() {
        let markdown = "# Title\n\nSome **bold** text with [a link](https://example.com) and ![img](noteasset:x.png)."
        let cleaned = SemanticIndexService.normalize(markdown)
        #expect(!cleaned.contains("#"))
        #expect(!cleaned.contains("**"))
        #expect(!cleaned.contains("https://example.com"))
        #expect(cleaned.contains("a link"))
        #expect(!cleaned.contains("noteasset"))
    }
}
