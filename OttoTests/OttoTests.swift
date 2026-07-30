import Testing
import Foundation
@testable import Otto

struct OttoTests {

    // MARK: - OttoTools tool-name canonicalization

    @Test func canonicalToolNameStripsMcpPrefix() {
        #expect(OttoTools.canonicalToolName("mcp__otto__attach_item_preview") == "attach_item_preview")
        #expect(OttoTools.canonicalToolName("mcp__calendar__list_events") == "list_events")
    }

    @Test func canonicalToolNameLeavesBareNamesAlone() {
        #expect(OttoTools.canonicalToolName("attach_item_preview") == "attach_item_preview")
        #expect(OttoTools.canonicalToolName("search_items") == "search_items")
        // A lone "mcp__" with no second separator shouldn't be mangled.
        #expect(OttoTools.canonicalToolName("mcp__weird") == "mcp__weird")
    }

    @Test func isAttachItemPreviewMatchesAllNamings() {
        #expect(OttoTools.isAttachItemPreview("attach_item_preview"))
        #expect(OttoTools.isAttachItemPreview("mcp__otto__attach_item_preview"))
        #expect(OttoTools.isAttachItemPreview("Attach Item Preview"))
        #expect(!OttoTools.isAttachItemPreview("search_items"))
        #expect(!OttoTools.isAttachItemPreview("mcp__otto__get_item"))
    }

    // MARK: - Preview type mapping

    @Test func previewContentTypeMapsSnakeCaseNames() {
        #expect(OttoTools.previewContentType("network") == .networkHub)
        #expect(OttoTools.previewContentType("x_post") == .xPost)
        #expect(OttoTools.previewContentType("x_follower") == .xFollower)
        #expect(OttoTools.previewContentType("x_dm") == .xDm)
        #expect(OttoTools.previewContentType("todo") == .todo)
        #expect(OttoTools.previewContentType("connection") == .connection)
        #expect(OttoTools.previewContentType("file") == .file)
        #expect(OttoTools.previewContentType("nonsense") == nil)
    }

    // MARK: - Preview recovery from the executor's result line

    @Test func parsePreviewResultExtractsTypeAndId() {
        let id = UUID()
        let parsed = OttoTools.parsePreviewResult("Attached preview: connection \(id.uuidString) — Adam Shuaib, PhD")
        #expect(parsed?.typeString == "connection")
        #expect(parsed?.id == id)
    }

    @Test func parsePreviewResultHandlesJsonWrappedSummary() {
        // Over MCP the tool result reaches the UI wrapped as {"result": "..."}.
        let id = UUID()
        let parsed = OttoTools.parsePreviewResult(#"{"result": "Attached preview: meeting \#(id.uuidString) — E2vc webinar"}"#)
        #expect(parsed?.typeString == "meeting")
        #expect(parsed?.id == id)
    }

    @Test func parsePreviewResultRejectsErrors() {
        #expect(OttoTools.parsePreviewResult(#"{"error": "No connection found with id 361F9B43."}"#) == nil)
        #expect(OttoTools.parsePreviewResult("Attached preview: connection not-a-uuid — x") == nil)
    }

    // MARK: - Inline otto:// item links

    @Test func parseItemURLHandlesAllTypeSpellings() throws {
        let id = UUID()
        let cases: [(String, ContentType)] = [
            ("otto://connection/\(id.uuidString)", .connection),
            ("otto://network/\(id.uuidString)", .networkHub),
            ("otto://x_post/\(id.uuidString)", .xPost),
            ("otto://meeting/\(id.uuidString)", .meeting),
            ("otto://file/\(id.uuidString)", .file),
        ]
        for (raw, expected) in cases {
            let url = try #require(URL(string: raw))
            let parsed = OttoTools.parseItemURL(url)
            #expect(parsed?.type == expected)
            #expect(parsed?.id == id)
        }
    }

    @Test func parseItemURLRejectsForeignSchemesAndGarbage() throws {
        #expect(OttoTools.parseItemURL(try #require(URL(string: "https://example.com/x"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://connection/not-a-uuid"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://nonsense/\(UUID().uuidString)"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://connection"))) == nil)
    }

    // MARK: - Attachment flattening (uploads reaching the model)

    @Test func flattenInlinesTextAttachmentContents() {
        let md = ChatAttachment(
            filename: "notes.md",
            mediaType: "text/markdown",
            data: Data("# Title\n\nSome **bold** body".utf8)
        )
        let turn = ChatTurn(role: "user", blocks: [.text("summarize this")], attachments: [md])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("summarize this"))
        #expect(flat.contains("Attached file: notes.md"))
        #expect(flat.contains("# Title"))
        #expect(flat.contains("Some **bold** body"))
        #expect(flat.contains("End of attached file: notes.md"))
    }

    @Test func flattenStubsBinaryAttachments() {
        let img = ChatAttachment(
            filename: "photo.png",
            mediaType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let turn = ChatTurn(role: "user", blocks: [.text("look at this")], attachments: [img])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("photo.png"))
        #expect(flat.contains("content not inlined"))
    }

    @Test func flattenTruncatesOversizedTextAttachments() {
        let big = String(repeating: "a", count: 40_000)
        let file = ChatAttachment(filename: "big.log", mediaType: "text/plain", data: Data(big.utf8))
        let turn = ChatTurn(role: "user", blocks: [.text("read this")], attachments: [file])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("truncated"))
        #expect(flat.count < 33_000)  // 32k cap + markers, not the raw 40k
    }

    @Test func markdownAttachmentClassification() {
        let md = ChatAttachment(filename: "README.md", mediaType: "text/markdown", data: Data("hello".utf8))
        #expect(md.kind == .text)
        #expect(md.isMarkdown)
        #expect(md.textContent == "hello")

        let csv = ChatAttachment(filename: "data.csv", mediaType: "text/csv", data: Data("a,b".utf8))
        #expect(csv.kind == .text)
        #expect(!csv.isMarkdown)

        let xlsx = ChatAttachment(filename: "sheet.xlsx", mediaType: "application/vnd.ms-excel", data: Data([0x50]))
        #expect(xlsx.kind == .binary)
        #expect(xlsx.textContent == nil)
    }

    @Test func markdownFallbackMediaType() {
        #expect(ChatAttachment.fallbackMediaType(forExtension: "md") == "text/markdown")
        #expect(ChatAttachment.fallbackMediaType(forExtension: "MARKDOWN") == "text/markdown")
        #expect(ChatAttachment.fallbackMediaType(forExtension: "bin") == "application/octet-stream")
    }

    // MARK: - ACP tool_call rawInput parsing

    @Test func acpToolCallCarriesRawInput() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc1","title":"mcp__otto__attach_item_preview","kind":"fetch","rawInput":{"type":"connection","id":"E70011F6-539E-44BD-AC51-C5800F01C526"}}}}
        """
        guard case .sessionUpdate(_, .toolCall(let id, let title, _, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCall session update")
            return
        }
        #expect(id == "tc1")
        #expect(title == "mcp__otto__attach_item_preview")
        #expect(rawInput?["type"] as? String == "connection")
        #expect(rawInput?["id"] as? String == "E70011F6-539E-44BD-AC51-C5800F01C526")
    }

    @Test func acpToolCallUpdateCarriesRawInputAndSummary() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc1","status":"completed","rawInput":{"type":"todo","id":"11111111-2222-3333-4444-555555555555"},"content":[{"type":"content","content":{"type":"text","text":"Attached preview: todo 11111111-2222-3333-4444-555555555555 — Ship it"}}]}}}
        """
        guard case .sessionUpdate(_, .toolCallUpdate(let id, let status, let summary, let isError, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCallUpdate session update")
            return
        }
        #expect(id == "tc1")
        #expect(status == "completed")
        #expect(!isError)
        #expect(summary.contains("Attached preview: todo"))
        #expect(rawInput?["type"] as? String == "todo")
    }

    @Test func acpToolCallWithoutRawInputStillParses() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc2","title":"mcp__otto__search_items"}}}
        """
        guard case .sessionUpdate(_, .toolCall(let id, _, _, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCall session update")
            return
        }
        #expect(id == "tc2")
        #expect(rawInput == nil)
    }
}

// MARK: - TaskSchedule occurrence math + scheduler decisions (Automations)

struct TaskSchedulerTests {

    /// Fixed calendar so results don't depend on the machine's timezone.
    /// Istanbul has had no DST since 2016 — stable wall-clock arithmetic.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi
        return cal.date(from: comps)!
    }

    // MARK: nextOccurrence

    @Test func dailyBeforeTimeFiresSameDay() {
        let s = TaskSchedule(days: .daily, hour: 9, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 7, 29, 7, 30), calendar: cal)
        #expect(next == date(2026, 7, 29, 9, 0))
    }

    @Test func dailyAfterTimeFiresTomorrow() {
        let s = TaskSchedule(days: .daily, hour: 9, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 7, 29, 9, 0), calendar: cal)
        #expect(next == date(2026, 7, 30, 9, 0))
    }

    @Test func weekdaySetPicksNearestListedDay() {
        // 2026-07-29 is a Wednesday; schedule runs Mondays only.
        let s = TaskSchedule(days: .weekdays([.mon]), hour: 9, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 7, 29, 12, 0), calendar: cal)
        #expect(next == date(2026, 8, 3, 9, 0))
    }

    @Test func weekdaySetPicksEarliestOfSeveral() {
        // Wednesday afternoon; {mon, thu} → Thursday the 30th, not next Monday.
        let s = TaskSchedule(days: .weekdays([.mon, .thu]), hour: 9, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 7, 29, 12, 0), calendar: cal)
        #expect(next == date(2026, 7, 30, 9, 0))
    }

    @Test func monthlyClampsToShortMonths() {
        // "31st" in February 2026 (28 days) → Feb 28.
        let s = TaskSchedule(days: .monthly(day: 31), hour: 8, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 2, 10, 12, 0), calendar: cal)
        #expect(next == date(2026, 2, 28, 8, 0))
    }

    @Test func monthlyRollsToNextMonth() {
        let s = TaskSchedule(days: .monthly(day: 15), hour: 8, minute: 0)
        let next = s.nextOccurrence(after: date(2026, 3, 20, 12, 0), calendar: cal)
        #expect(next == date(2026, 4, 15, 8, 0))
    }

    // MARK: evaluate — the anacron rule

    private func task(
        due: Date?,
        lastRun: Date? = nil,
        enabled: Bool = true,
        catchUp: ScheduledTask.CatchUpPolicy = .runASAP
    ) -> ScheduledTask {
        ScheduledTask(
            name: "t", prompt: "p",
            schedule: TaskSchedule(days: .daily, hour: 9, minute: 0),
            isEnabled: enabled, catchUpPolicy: catchUp,
            nextDueAt: due, lastRunAt: lastRun
        )
    }

    @Test func waitsBeforeDue() {
        let t = task(due: date(2026, 7, 29, 9, 0))
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 8, 59), calendar: cal)
        #expect(action == .wait)
    }

    @Test func runsOnTime() {
        let due = date(2026, 7, 29, 9, 0)
        let t = task(due: due, lastRun: date(2026, 7, 28, 9, 0))
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 9, 0), calendar: cal)
        #expect(action == .run(scheduledFor: due))
    }

    @Test func catchesUpLaterSameDay() {
        // The user's exact scenario: 9:00 task, Mac opened at 10:00.
        let due = date(2026, 7, 29, 9, 0)
        let t = task(due: due, lastRun: date(2026, 7, 28, 9, 0))
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 10, 0), calendar: cal)
        #expect(action == .run(scheduledFor: due))
    }

    @Test func catchesUpAfterMultiDayGapOnce() {
        // Mac off since Monday; due Tue 9:00; opened Wed 7:00 → run now.
        let due = date(2026, 7, 28, 9, 0)
        let t = task(due: due, lastRun: date(2026, 7, 27, 9, 0))
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 7, 0), calendar: cal)
        #expect(action == .run(scheduledFor: due))
    }

    @Test func oncePerDayGuardSuppressesSameDayRefire() {
        // The 7:00 catch-up above ran (lastRun = today 7:00) and advanced the
        // due date to today 9:00. At 9:00 the task must NOT run again — it
        // advances silently to tomorrow.
        let t = task(due: date(2026, 7, 29, 9, 0), lastRun: date(2026, 7, 29, 7, 0))
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 9, 0), calendar: cal)
        #expect(action == .advance(to: date(2026, 7, 30, 9, 0)))
    }

    @Test func skipPolicySkipsFullyMissedDay() {
        // skip-to-next task due Monday 9:00; app first opened Wednesday →
        // don't run a stale day, advance to the next occurrence.
        let t = task(due: date(2026, 7, 27, 9, 0), lastRun: date(2026, 7, 26, 9, 0), catchUp: .skipToNext)
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 11, 0), calendar: cal)
        #expect(action == .advance(to: date(2026, 7, 30, 9, 0)))
    }

    @Test func skipPolicyStillRunsLateOnTheScheduledDay() {
        let due = date(2026, 7, 29, 9, 0)
        let t = task(due: due, lastRun: date(2026, 7, 28, 9, 0), catchUp: .skipToNext)
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 11, 0), calendar: cal)
        #expect(action == .run(scheduledFor: due))
    }

    @Test func disabledTaskNeverRuns() {
        let t = task(due: date(2026, 7, 29, 9, 0), enabled: false)
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 10, 0), calendar: cal)
        #expect(action == .wait)
    }

    @Test func missingDueDateGetsSeeded() {
        let t = task(due: nil)
        let action = TaskSchedulerService.evaluate(task: t, now: date(2026, 7, 29, 10, 0), calendar: cal)
        #expect(action == .advance(to: date(2026, 7, 30, 9, 0)))
    }

    // MARK: schedule Codable round-trip

    @Test func scheduleRoundTripsThroughJSON() throws {
        let original = ScheduledTask(
            name: "Digest", prompt: "Summarize",
            schedule: TaskSchedule(days: .weekdays([.mon, .wed]), hour: 14, minute: 30),
            catchUpPolicy: .skipToNext,
            autoApproveTools: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        #expect(decoded == original)
    }

    @Test func legacyTaskJSONDefaultsAutoApproveOff() throws {
        // Tasks saved before the auto-approve toggle existed decode with it off.
        let data = try JSONEncoder().encode(ScheduledTask(name: "t", prompt: "p"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "autoApproveTools")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: stripped)
        #expect(decoded.autoApproveTools == false)
    }

    @Test func chatSessionDecodesLegacyJSONWithoutPinFlag() throws {
        // Sessions saved before titlePinned existed must keep decoding (a
        // decode failure would silently wipe ALL chat history via the store's
        // lenient fallback).
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Old chat","turns":[],"createdAt":712627200,"updatedAt":712627200}
        """
        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(legacy.utf8))
        #expect(decoded.titlePinned == false)
        #expect(decoded.title == "Old chat")
    }
}
