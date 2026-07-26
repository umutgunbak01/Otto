import Foundation
import Observation

/// Turns a finished meeting transcript into a Meeting record + to-dos, via a
/// headless agent run.
///
/// Follows the `DailyBriefingService` pattern exactly: one-shot run on the
/// user's chat backend with a throwaway `sessionKey`, no-op stream callbacks,
/// and no `ChatRunController` involvement — so nothing ever appears in chat
/// history. The agent returns strict JSON; Otto (not the agent) performs the
/// writes, so results are deterministic and no tool approvals can stall a
/// background Hermes run.
///
/// Failure is non-destructive: if the agent run or parse fails, the raw
/// transcript is still saved as a Meeting so nothing is lost.
@MainActor
@Observable
final class MeetingAnalysisService {
    static let shared = MeetingAnalysisService()

    private(set) var isAnalyzing = false
    /// Title shown by the Meetings tab's "Generating…" placeholder row. Set by
    /// `MeetingRecorder` the moment recording stops (so the row appears while
    /// in-flight transcriptions drain), cleared when the Meeting lands.
    private(set) var pendingTitle: String?

    private init() {}

    func beginPending(title: String) {
        pendingTitle = title
    }

    func endPending() {
        pendingTitle = nil
    }

    // MARK: - Entry point

    func analyze(
        transcript: String,
        context: MeetingRecorder.Context?,
        startedAt: Date,
        duration: Int,
        appState: AppState
    ) {
        Task { [weak appState] in
            defer {
                isAnalyzing = false
                endPending()
            }
            guard let appState else { return }
            isAnalyzing = true
            await run(
                transcript: transcript, context: context,
                startedAt: startedAt, duration: duration, appState: appState
            )
        }
    }

    private func run(
        transcript: String,
        context: MeetingRecorder.Context?,
        startedAt: Date,
        duration: Int,
        appState: AppState
    ) async {
        let fallbackTitle = context?.displayTitle ?? "Meeting — \(Self.dayFormatter.string(from: startedAt))"

        guard let backend = pickBackend() else {
            NSLog("[MeetingAnalysis] no agent backend available — saving raw transcript only")
            await saveFallbackMeeting(
                title: fallbackTitle, transcript: transcript, context: context,
                startedAt: startedAt, duration: duration, appState: appState
            )
            return
        }

        // Layer 1: calendar attendees resolved to real names via the user's
        // Connections / Network Hub, self excluded.
        let resolved = Self.resolveParticipants(
            event: context?.calendarEvent, appState: appState
        )

        let notesLanguage = MeetingNotesLanguageSettings.current

        let payload: Payload
        do {
            let executor = OttoToolExecutor(appState: appState)
            let userPrompt = Self.userPrompt(
                transcript: transcript, context: context, startedAt: startedAt,
                duration: duration, attendees: resolved.others, selfEmail: resolved.selfEmail,
                prep: context?.prep ?? MeetingPrep()
            )
            let turns = [ChatTurn(role: "user", blocks: [.text(userPrompt)])]
            let result = try await Self.runBackend(
                backend: backend,
                sessionKey: UUID(),   // fresh key: system prompt always delivered, run isolated
                turns: turns,
                systemPrompt: Self.analysisSystemPrompt(language: notesLanguage),
                executor: executor
            )
            let text = Self.finalAssistantText(result)
            payload = try Self.parse(text)
        } catch {
            NSLog("[MeetingAnalysis] agent run failed (%@) — saving raw transcript only", error.localizedDescription)
            await saveFallbackMeeting(
                title: fallbackTitle, transcript: transcript, context: context,
                startedAt: startedAt, duration: duration, appState: appState
            )
            return
        }

        // The fixed strings Otto weaves around the agent's text (headings,
        // owner labels) are kept in Turkish or English. Under `.auto` the
        // agent reports what it wrote in via `language`; a third language
        // gets its notes verbatim but English fixed strings.
        let turkishPrimary: Bool
        switch notesLanguage {
        case .turkish: turkishPrimary = true
        case .english: turkishPrimary = false
        case .auto:    turkishPrimary = payload.language.lowercased().hasPrefix("tr")
        }
        let englishPrimary = notesLanguage == .english
            || (notesLanguage == .auto && (payload.language.isEmpty || payload.language.lowercased().hasPrefix("en")))

        // Assemble the Meeting record. The raw transcript goes into the
        // dedicated `transcript` field, rendered by the detail view's
        // transcript pane.
        var content = payload.notes
        if !payload.insights.isEmpty {
            content += "\n\n" + (turkishPrimary ? "## Öne Çıkanlar" : "## Insights")
                + "\n" + payload.insights.map { "- \($0)" }.joined(separator: "\n")
        }
        // Non-English notes carry an English mirror at the bottom, clearly
        // separated so it stays "on the side" for sharing/reference.
        if !englishPrimary {
            let englishSection = Self.englishReferenceSection(payload)
            if !englishSection.isEmpty {
                content += "\n\n---\n\n" + englishSection
            }
        }

        let actionItemsMarkdown = payload.actionItems.map { item -> String in
            let owner = item.isMine ? (turkishPrimary ? "Ben" : "Me") : (turkishPrimary ? "Onlar" : "Them")
            var line = "- **[\(owner)]** \(item.title)"
            if let due = item.dueDate, !due.isEmpty {
                line += turkishPrimary ? " — son tarih \(due)" : " — due \(due)"
            }
            if let notes = item.notes, !notes.isEmpty { line += " (\(notes))" }
            return line
        }.joined(separator: "\n")

        // Participant names the user typed in the prep panel are authoritative
        // (they know who was there); calendar names come next, then anyone the
        // agent additionally heard addressed in the conversation.
        var participants = resolved.others.map(\.shortName)
        for manual in (context?.prep.participantNames ?? []) {
            let lower = manual.lowercased()
            if !participants.contains(where: { $0.lowercased() == lower }) {
                participants.insert(manual, at: 0)
            }
        }
        for extra in payload.participants {
            let lower = extra.lowercased()
            if !participants.contains(where: {
                $0.lowercased() == lower || lower.contains($0.lowercased()) || $0.lowercased().contains(lower)
            }) {
                participants.append(extra)
            }
        }

        let meeting = Meeting(
            title: payload.title.isEmpty ? fallbackTitle : payload.title,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            overview: payload.overview,
            actionItems: actionItemsMarkdown,
            participants: participants,
            duration: duration,
            meetingDate: startedAt,
            transcript: transcript
        )
        await appState.addMeeting(meeting)

        // Only the user's own commitments become to-dos.
        var created = 0
        for item in payload.actionItems where item.isMine && !item.title.isEmpty {
            var description = (turkishPrimary ? "Toplantıdan: " : "From meeting: ") + meeting.title
            if let notes = item.notes, !notes.isEmpty { description += "\n\(notes)" }
            let todo = Todo(
                title: item.title,
                description: description,
                dueDate: Self.parseDueDate(item.dueDate),
                priority: Self.parsePriority(item.priority)
            )
            await appState.addTodo(todo)
            created += 1
        }

        NSLog("[MeetingAnalysis] saved meeting \"%@\" with %d to-dos", meeting.title, created)

        let body = created > 0
            ? "Summary and notes saved. \(created) action item\(created == 1 ? "" : "s") added to your to-dos."
            : "Summary and notes saved to the Meetings tab."
        try? await NotificationService.shared.notifyMeetingReady(
            meetingId: meeting.id,
            title: "Meeting notes ready: \(meeting.title)",
            body: body
        )
    }

    /// Analysis failed — keep the raw transcript as a bare meeting so the
    /// capture is never lost.
    private func saveFallbackMeeting(
        title: String, transcript: String, context: MeetingRecorder.Context?,
        startedAt: Date, duration: Int, appState: AppState
    ) async {
        let meeting = Meeting(
            title: title,
            content: "Automatic analysis didn't complete — the full transcript is in the Transcript pane.",
            participants: Self.resolveParticipants(
                event: context?.calendarEvent, appState: appState
            ).others.map(\.shortName),
            duration: duration,
            meetingDate: startedAt,
            transcript: transcript
        )
        await appState.addMeeting(meeting)
        try? await NotificationService.shared.notifyMeetingReady(
            meetingId: meeting.id,
            title: "Meeting transcript saved",
            body: "Analysis didn't complete, but the full transcript is in the Meetings tab."
        )
    }

    // MARK: - Backend plumbing (same shape as DailyBriefingService)

    private func pickBackend() -> AgentBackend? {
        switch AgentBackend.current {
        case .claude:
            return ClaudeAuthService.shared.effectiveAuthMode() != .none ? .claude : nil
        case .codex:
            return CodexAuthService.shared.effectiveAuthMode() != .none ? .codex : nil
        case .hermes:
            return HermesInstallation.binaryPath() != nil ? .hermes : nil
        }
    }

    private static func runBackend(
        backend: AgentBackend,
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        executor: OttoToolExecutor
    ) async throws -> [ChatTurn] {
        switch backend {
        case .claude:
            return try await ClaudeCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .codex:
            return try await CodexCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        case .hermes:
            return try await HermesAgentService.shared.streamChatWithTools(
                sessionKey: sessionKey, turns: turns, systemPrompt: systemPrompt,
                tools: OttoTools.all, executor: executor, onDelta: { _ in }, onEvent: { _ in }
            )
        }
    }

    private static func finalAssistantText(_ turns: [ChatTurn]) -> String {
        guard let last = turns.last(where: { $0.role == "assistant" }) else { return "" }
        return last.blocks.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Participant resolution

    struct ResolvedParticipant {
        let email: String
        let name: String?

        /// "Emir Kaya <emir@…>" when the contact is known, bare email otherwise.
        var promptLabel: String { name.map { "\($0) <\(email)>" } ?? email }
        /// What lands in `Meeting.participants`.
        var shortName: String { name ?? email }
    }

    /// Map the calendar event's attendee emails to real people via the
    /// Connections CRM and the Network Hub, excluding the user themself.
    @MainActor
    static func resolveParticipants(
        event: CalendarEvent?,
        appState: AppState
    ) -> (others: [ResolvedParticipant], selfEmail: String?) {
        let selfEmail = appState.firefliesSyncSettings.userEmail
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let event else { return ([], selfEmail.isEmpty ? nil : selfEmail) }

        var others: [ResolvedParticipant] = []
        for raw in event.attendees {
            let email = raw.trimmingCharacters(in: .whitespaces)
            let lower = email.lowercased()
            guard !lower.isEmpty, lower != selfEmail else { continue }

            var name: String?
            if let match = appState.connections.first(where: { $0.email?.lowercased() == lower }) {
                let full = match.fullName.trimmingCharacters(in: .whitespaces)
                if !full.isEmpty { name = full }
            }
            if name == nil,
               let match = appState.networkEntries.first(where: { $0.email.lowercased() == lower }) {
                let full = match.name.trimmingCharacters(in: .whitespaces)
                if !full.isEmpty { name = full }
            }
            others.append(ResolvedParticipant(email: email, name: name))
        }
        return (others, selfEmail.isEmpty ? nil : selfEmail)
    }

    // MARK: - Prompts

    private static func analysisSystemPrompt(language: MeetingNotesLanguage) -> String {
        let languageRules: String
        switch language {
        case .english:
            languageRules = """
            LANGUAGE:
            - Write every human-readable field (`title`, `overview`, `insights`, `notes`, and each action item's `title` and `notes`) in ENGLISH, regardless of what language the meeting was spoken in. Section headings too — including any headings named in the note-style guidance.
            - Never translate people's names.
            - Set `language` to "en". Omit the `*_en` mirror fields.
            """
        case .turkish:
            languageRules = """
            LANGUAGE:
            - Write every human-readable field (`title`, `overview`, `insights`, `notes`, and each action item's `title` and `notes`) in TURKISH, regardless of what language the meeting was spoken in. Section headings too — including any headings named in the note-style guidance.
            - Also provide a faithful ENGLISH translation of the main text in the mirror fields `overview_en`, `insights_en`, and `notes_en` — same content, same items, same order.
            - Never translate people's names.
            - Set `language` to "tr".
            """
        case .auto:
            languageRules = """
            LANGUAGE:
            - Detect the language the meeting was mostly spoken in, and write every human-readable field (`title`, `overview`, `insights`, `notes`, and each action item's `title` and `notes`) in THAT language. Section headings too — including any headings named in the note-style guidance.
            - If that language is not English, also provide a faithful ENGLISH translation of the main text in the mirror fields `overview_en`, `insights_en`, and `notes_en` — same content, same items, same order. If it is English, omit the mirror fields.
            - Never translate people's names.
            - Set `language` to the primary language's two-letter code ("en", "tr", "de", …).
            """
        }

        return """
    You analyze meeting transcripts for the user. The transcript labels speakers: "Me" is the user (the app's owner), "Them" is everyone else on the call. Do NOT call any tools — synthesize from the transcript alone.

    \(languageRules)

    Reply with STRICT JSON only — no markdown fences, no prose before or after the JSON object. Schema:
    {
      "title": "short descriptive meeting title, ≤60 chars (use the calendar title if one was given)",
      "language": "two-letter code of the primary language the fields are written in",
      "overview": "2–4 sentence summary of what the meeting was about and what was decided",
      "overview_en": "the SAME overview in English (only when the primary language is not English)",
      "insights": ["notable takeaway, risk, opportunity, or decision — the non-obvious stuff worth remembering"],
      "insights_en": ["the SAME insights in English, same order (only when the primary language is not English)"],
      "notes": "markdown notes of the discussion: key points organized under ## headings, concise but complete",
      "notes_en": "the SAME notes in English markdown (only when the primary language is not English)",
      "action_items": [
        {
          "title": "imperative phrasing of the task",
          "owner": "me" or "them",
          "due_date": "YYYY-MM-DD" or null,
          "notes": "1 short sentence of context from the meeting" or null,
          "priority": "low" | "medium" | "high" | "urgent"
        }
      ],
      "participants": ["names of people on the call, from the transcript or the attendee list"]
    }

    Rules for action_items:
    - owner "me" = something the user ("Me" speaker) committed to or was asked to do; owner "them" = the other side's commitments. When genuinely unclear, use "them" — never invent work for the user.
    - Resolve relative dates ("by Friday", "next week") to absolute YYYY-MM-DD using the meeting date given in the prompt. If no timing was mentioned, use null — do not guess.
    - Only real commitments made in the meeting; not ideas, not "we should someday".

    Using attendee names (when the prompt lists attendees):
    - People address each other by name in conversation — use that plus the attendee list to attribute what "Them" said to specific people, and refer to people by name in notes, insights, and action items ("Emir will send the deck", not "they will send the deck").
    - "participants" should be the real names of people actually on the call — attendee names where confirmed, plus anyone else clearly present from the conversation.
    - Never invent or guess names. If the dialogue doesn't make clear who spoke, keep the generic phrasing.

    Limits: insights ≤6, action_items ≤10. Transcription is imperfect — ignore obvious mis-transcriptions and filler.
    """
    }

    /// Builds the trailing "## English (reference)" block appended after
    /// non-English notes. Only includes the pieces the agent actually
    /// translated — if the `*_en` mirror fields came back empty, the whole
    /// block is omitted rather than showing something broken.
    private static func englishReferenceSection(_ payload: Payload) -> String {
        var parts: [String] = []
        let overviewEn = payload.overviewEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesEn = payload.notesEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let insightsEn = payload.insightsEn.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if !overviewEn.isEmpty { parts.append(overviewEn) }
        if !notesEn.isEmpty { parts.append(notesEn) }
        if !insightsEn.isEmpty {
            parts.append("### Insights\n" + insightsEn.map { "- \($0)" }.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return "" }
        return "## English (reference)\n\n" + parts.joined(separator: "\n\n")
    }

    private static func userPrompt(
        transcript: String,
        context: MeetingRecorder.Context?,
        startedAt: Date,
        duration: Int,
        attendees: [ResolvedParticipant],
        selfEmail: String?,
        prep: MeetingPrep
    ) -> String {
        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm"

        var lines: [String] = []
        lines.append("Analyze this meeting transcript.")
        lines.append("")
        lines.append("Meeting date: \(headerFormatter.string(from: startedAt)) (\(TimeZone.current.identifier))")
        lines.append("Duration: \(max(1, duration / 60)) minutes")
        if let event = context?.calendarEvent {
            lines.append("Calendar event: \"\(event.title)\"")
        } else if let appName = context?.appName {
            lines.append("Captured from: \(appName)")
        }

        // Prep the user entered in the notch panel. Purpose/focus steer the
        // synthesis; the note style dictates the section structure.
        let purpose = prep.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty {
            lines.append("Meeting purpose (stated by the user): \(purpose)")
        }
        lines.append("Note style: \(prep.noteStyle.promptGuidance)")
        let focus = prep.focusPoints.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty {
            lines.append("The user asked you to pay special attention to: \(focus) — make sure the notes and action items cover this.")
        }

        if let selfEmail {
            lines.append("The user — the \"Me\" speaker — is \(selfEmail).")
        }

        // Names the user typed in are the ground truth for who was on the call —
        // use them to attribute what "Them" said instead of generic phrasing.
        if !prep.participantNames.isEmpty {
            lines.append("People on the call (entered by the user — treat as authoritative for attribution): \(prep.participantNames.joined(separator: ", ")).")
        }
        if !attendees.isEmpty {
            lines.append("Other attendees from the calendar invite (resolved against the user's contacts; these are the likely \"Them\" speakers):")
            for p in attendees {
                lines.append("- \(p.promptLabel)")
            }
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    private struct ActionItem: Decodable {
        var title = ""
        var owner: String?
        var dueDate: String?
        var notes: String?
        var priority: String?

        var isMine: Bool { owner?.lowercased() == "me" }

        enum CodingKeys: String, CodingKey {
            case title, owner, notes, priority
            case dueDate = "due_date"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            owner = try? c.decode(String.self, forKey: .owner)
            dueDate = try? c.decode(String.self, forKey: .dueDate)
            notes = try? c.decode(String.self, forKey: .notes)
            priority = try? c.decode(String.self, forKey: .priority)
        }
    }

    private struct Payload: Decodable {
        var title = ""
        /// Two-letter code of the language the agent wrote the fields in —
        /// how `.auto` mode learns what the meeting's language was.
        var language = ""
        var overview = ""
        var insights: [String] = []
        var notes = ""
        /// English mirrors, present only when the primary language isn't
        /// English — rendered as the "## English (reference)" section.
        var overviewEn = ""
        var insightsEn: [String] = []
        var notesEn = ""
        var actionItems: [ActionItem] = []
        var participants: [String] = []

        enum CodingKeys: String, CodingKey {
            case title, language, overview, insights, notes, participants
            case overviewEn = "overview_en"
            case insightsEn = "insights_en"
            case notesEn = "notes_en"
            case actionItems = "action_items"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            language = (try? c.decode(String.self, forKey: .language)) ?? ""
            overview = (try? c.decode(String.self, forKey: .overview)) ?? ""
            insights = (try? c.decode([String].self, forKey: .insights)) ?? []
            notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
            overviewEn = (try? c.decode(String.self, forKey: .overviewEn)) ?? ""
            insightsEn = (try? c.decode([String].self, forKey: .insightsEn)) ?? []
            notesEn = (try? c.decode(String.self, forKey: .notesEn)) ?? ""
            actionItems = (try? c.decode([ActionItem].self, forKey: .actionItems)) ?? []
            participants = (try? c.decode([String].self, forKey: .participants)) ?? []
        }
    }

    enum AnalysisError: LocalizedError {
        case emptyReply
        case unparseable

        var errorDescription: String? {
            switch self {
            case .emptyReply:  return "The agent returned an empty reply."
            case .unparseable: return "Couldn't parse the analysis reply."
            }
        }
    }

    /// Slice to the outermost JSON object and decode leniently — same defense
    /// against fences/prose as DailyBriefingService.
    private static func parse(_ text: String) throws -> Payload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnalysisError.emptyReply }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end,
              let data = String(trimmed[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw AnalysisError.unparseable }
        guard !payload.overview.isEmpty || !payload.notes.isEmpty || !payload.actionItems.isEmpty else {
            throw AnalysisError.unparseable
        }
        return payload
    }

    private static func parseDueDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw.lowercased() != "null" else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        guard let day = fmt.date(from: String(raw.prefix(10))) else { return nil }
        // Noon local — keeps the date stable across timezone math in list views.
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }

    private static func parsePriority(_ raw: String?) -> Todo.Priority {
        switch raw?.lowercased() {
        case "low": return .low
        case "high": return .high
        case "urgent": return .urgent
        default: return .medium
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}
