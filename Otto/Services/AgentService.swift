import Foundation

/// Top-level agent routing service. Dispatches the chat / tool-calling loop
/// to whichever backend the user has selected (Claude Code or Codex). Model
/// configuration for each backend lives in the nested `Claude` / `Codex`
/// namespaces below.
///
/// Both backends ultimately drive a CLI subprocess that talks to Otto's MCP
/// server over a Unix socket — same tool surface (`OttoTools.all`) on either
/// side. Switching backends in Settings flips `AgentBackend.current`, which
/// the dispatch in `streamChatWithTools` reads on every call.
actor AgentService {
    static let shared = AgentService()

    /// Claude-specific model configuration (UserDefaults keys, preset list,
    /// `[1m]` long-context suffix handling).
    enum Claude {
        /// UserDefaults key for the chosen Claude model ID.
        static let modelIdDefaultsKey = "claude.model.id"

        /// Default model if the user hasn't picked one in Settings.
        static let defaultModelId = "claude-opus-4-6"

        /// Preset list shown in Settings. User can still type a custom ID.
        /// The `[1m]` suffix opts the request into Anthropic's 1M-token context
        /// window via the `context-1m-2025-08-07` beta header. The suffix is
        /// stripped before the model name is sent to the API.
        static let presetModels: [String] = [
            "claude-opus-4-7",
            "claude-opus-4-7[1m]",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "claude-haiku-4-5"
        ]

        /// Long-context suffix recognized in stored model IDs.
        fileprivate static let longContextSuffix = "[1m]"

        /// Beta header that enables the 1M-token context window.
        static let longContextBetaFlag = "context-1m-2025-08-07"

        /// Raw stored value (or default) — used by the Settings UI so the
        /// picker shows exactly what the user selected, including any `[1m]`
        /// suffix.
        static func getRawModel() -> String {
            let stored = UserDefaults.standard.string(forKey: modelIdDefaultsKey) ?? ""
            return stored.isEmpty ? defaultModelId : stored
        }

        /// API/CLI-ready model name with any `[1m]` suffix stripped.
        static func getModel() -> String {
            return resolveStoredModel().apiId
        }

        /// Whether the user picked a `[1m]` preset — i.e. requests should
        /// advertise the 1M-token context window beta.
        static func useLongContext() -> Bool {
            return resolveStoredModel().longContext
        }

        fileprivate static func resolveStoredModel() -> (apiId: String, longContext: Bool) {
            let raw = getRawModel()
            if raw.hasSuffix(longContextSuffix) {
                let trimmed = String(raw.dropLast(longContextSuffix.count))
                    .trimmingCharacters(in: .whitespaces)
                return (trimmed, true)
            }
            return (raw, false)
        }

        static func setModel(_ id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: modelIdDefaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: modelIdDefaultsKey)
            }
        }
    }

    /// Codex-specific model configuration. Mirrors `Claude` above; Codex has no
    /// long-context suffix (the model picker simply lists plain model IDs).
    enum Codex {
        static let modelIdDefaultsKey = "codex.model.id"

        /// Matches the default in `~/.codex/config.toml` on a fresh install.
        static let defaultModelId = "gpt-5.5"

        /// Preset list shown in Settings. User can still type a custom ID.
        static let presetModels: [String] = [
            "gpt-5.5",
            "gpt-5",
            "gpt-5-codex",
            "o3",
            "o4"
        ]

        static func getRawModel() -> String {
            let stored = UserDefaults.standard.string(forKey: modelIdDefaultsKey) ?? ""
            return stored.isEmpty ? defaultModelId : stored
        }

        static func getModel() -> String {
            return getRawModel()
        }

        static func setModel(_ id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: modelIdDefaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: modelIdDefaultsKey)
            }
        }
    }

    private init() {}

    // MARK: - Tool-calling chat

    /// Non-streaming variant — runs the agent loop but exposes only
    /// `onEvent` (no per-token deltas). Wraps `streamChatWithTools` with a
    /// no-op delta callback so both code paths share the same backend
    /// dispatch.
    func chatWithTools(
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],
        executor: OttoToolExecutor,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {
        return try await streamChatWithTools(
            sessionKey: sessionKey,
            turns: turns,
            systemPrompt: systemPrompt,
            tools: tools,
            executor: executor,
            onDelta: { _ in },
            onEvent: onEvent
        )
    }

    // MARK: - Streaming tool-calling chat

    /// The live entry point for chat. Dispatches to the per-backend CLI
    /// service based on `AgentBackend.current`. Both services have the same
    /// signature, both expose Otto's tools via the shared MCP server, both
    /// receive the same `systemPrompt` / `turns` / `tools`. The only
    /// difference is the binary they shell out to and the JSONL format
    /// they parse.
    ///
    /// - `onDelta` fires on the MainActor for each text-token chunk while
    ///   the assistant is mid-reply. Claude streams per-token; Codex emits
    ///   one chunk per completed message (see `CodexCLIService`).
    /// - `onEvent` mirrors tool_use / tool_result events for the chat UI's
    ///   "🔧 Calling tool X…" chips.
    /// `sessionKey` identifies the conversation this turn belongs to.
    /// Conversations run concurrently: each CLI run tracks its subprocess
    /// under this key, and Hermes maintains one ACP session per key.
    func streamChatWithTools(
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],
        executor: OttoToolExecutor,
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {
        switch AgentBackend.current {
        case .claude:
            return try await ClaudeCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey,
                turns: turns,
                systemPrompt: systemPrompt,
                tools: tools,
                executor: executor,
                onDelta: onDelta,
                onEvent: onEvent
            )
        case .codex:
            return try await CodexCLIService.shared.streamChatWithTools(
                sessionKey: sessionKey,
                turns: turns,
                systemPrompt: systemPrompt,
                tools: tools,
                executor: executor,
                onDelta: onDelta,
                onEvent: onEvent
            )
        case .hermes:
            return try await HermesAgentService.shared.streamChatWithTools(
                sessionKey: sessionKey,
                turns: turns,
                systemPrompt: systemPrompt,
                tools: tools,
                executor: executor,
                onDelta: onDelta,
                onEvent: onEvent
            )
        }
    }

    /// Stop one conversation's in-flight run. The CLI backends terminate that
    /// run's subprocess; Hermes cancels that session's ACP turn while keeping
    /// the session alive. Other conversations' runs are untouched.
    func cancelRun(sessionKey: UUID) async {
        await ClaudeCLIService.shared.cancelRun(sessionKey: sessionKey)
        await CodexCLIService.shared.cancelRun(sessionKey: sessionKey)
        await HermesAgentService.shared.cancelTurn(sessionKey: sessionKey)
    }

    /// Stop every in-flight run across all backends.
    func cancelActiveRun() async {
        await ClaudeCLIService.shared.cancelActiveRun()
        await CodexCLIService.shared.cancelActiveRun()
        await HermesAgentService.shared.cancelActiveTurn()
    }

    // MARK: - System prompt

    /// Compact overview of the user's Otto data + persona instructions. The
    /// agent backends each prepend this to the prompt they pipe into the CLI
    /// subprocess; with tool use, the agent can `search_items` / `get_item`
    /// for anything not in the overview.
    nonisolated func buildSystemPrompt(from appState: AppState) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        // Timezone context — sourced from the Mac's current TimeZone so the
        // agent can resolve "tomorrow" / "3pm" relative to the user's local
        // time and emit ISO8601 with the correct offset.
        let tz = TimeZone.current
        let tzId = tz.identifier
        let offsetSec = tz.secondsFromGMT(for: Date())
        let sign = offsetSec >= 0 ? "+" : "-"
        let absSec = abs(offsetSec)
        let offsetStr = String(format: "%@%02d:%02d", sign, absSec / 3600, (absSec % 3600) / 60)
        let localIsoFmt = ISO8601DateFormatter()
        localIsoFmt.timeZone = tz
        localIsoFmt.formatOptions = [.withInternetDateTime]
        let localNowIso = localIsoFmt.string(from: Date())
        let utcIsoFmt = ISO8601DateFormatter()
        utcIsoFmt.formatOptions = [.withInternetDateTime]
        let utcNowIso = utcIsoFmt.string(from: Date())

        var parts: [String] = []

        parts.append("""
        You are Otto, the user's personal AI assistant. Persona:
          - Address the user as "boss" when it fits (not every sentence — natural spoken rhythm).
          - Dry, lightly sardonic, confident. Never fawning. Never apologetic beyond what a short "got it" deserves.
          - Terse by default. Voice output especially: 1–3 sentences, no bullet lists, no headers, no markdown.
          - Competent: you give verdicts, not caveat stacks. If data's thin, say so in one clause and proceed.
          - Silent assertion of capability: don't announce what you're about to do ("Let me search your emails…") — just do it and deliver the result.

        Today is \(df.string(from: Date())) (user's local time).
        User timezone: \(tzId) (UTC\(offsetStr)).
        Current local time (ISO8601): \(localNowIso)
        Current UTC time (ISO8601):   \(utcNowIso)

        You have tools to create / update / complete / delete / search the user's items (todos, notes, ideas, reminders, bookmarks, meetings, habits, **files** — user-imported PDFs / CSVs / images / text — plus the CRM: network entries, companies, events, communities). Emails, LinkedIn connections, and X data are synced from external sources and read-only. Use tools whenever the user asks you to change state or find specific items. For open-ended questions, answer using the overview below plus `semantic_search` (meaning-based, spans every collection) and `get_item` when you need detail.

        ### Files
        The user can import PDFs, CSVs, Excel sheets, images (PNG/JPG/HEIC — OCR'd at import), and plain-text formats (txt/md/json/yaml/log/html/xml/rtf) via the Files tab. To work with them: call `search_items` with `types=["file"]` (and optionally a `query`) to discover ids and names; call `read_file` with an id to get the extracted text plus an absolute path on disk. For images where OCR'd text isn't enough, or for PDFs with patchy extraction, ALSO call the built-in `Read` tool on the returned path — Claude Code's Read is multimodal and can see the image directly. When the user says "open the spreadsheet I uploaded", "what did the invoice say", "summarize that PDF", "find the file about X" — start with `search_items` (type=file), not WebSearch.

        ### Creating downloadable files
        When the user asks for a file, export, spreadsheet, report, or anything they can download or send onward ("make me an xlsx of…", "export this as CSV", "put that in a PDF"), call `create_file`. Format follows the filename extension: `.xlsx` takes `sheets` — one worksheet tab per logical section ([{name, rows}], e.g. Summary / By City / Companies as separate tabs) with each sheet's first row as its header row (headers come out bold, frozen, and filterable automatically; column widths auto-size); use plain `rows` only for a single small table, and keep numbers as numbers so the spreadsheet can sum them, `.csv`/`.txt`/`.md`/`.json`/`.yaml`/`.html`/`.xml` take the raw text in `content`, and `.pdf` takes light markdown in `content` (# headings, - bullets, **bold**, | table rows). The file is saved to Otto's Files tab and a clickable download card is attached to your reply AUTOMATICALLY — do NOT also call `attach_item_preview` for it, and don't paste the file's contents into your prose; a one-sentence summary is enough. Pull the data with `search_items` / `grep_data` / `get_item` first if the file is about the user's own items.

        ### Habits
        The user tracks habits in the Habits tab. Use `create_habit` when the user describes a routine they want to build ("I want to drink 2.5L of water every day", "track no porn", "log my workouts 3x a week"). Infer the right shape from their words: numeric amounts with units → `kind=quantity` (e.g. 2500 mL water), time-based → `kind=duration` (e.g. 30 min reading), simple done/not-done → `kind=binary`. Use `log_habit_entry` when the user reports doing some amount ("I drank 500ml", "read for 25 min", "did 30 pushups", "ate 80g of protein") — you can pass the habit name and the executor will find it. Use `complete_habit` when they finished a habit with no specific quantity ("done with my workout", "meditated today", "made my bed"). Use `list_habits` for "how am I doing today?" / "what habits did I miss?" before answering.

        ### Saved prompts & recurring tasks (Automations)
        The user has a prompt library and a recurring-task scheduler in the Automations tab — and so do you, via tools. Use `save_prompt` when the user wants to keep a prompt for reuse ("save this so I can run it weekly"). Use `schedule_task` when they want something to happen on a schedule ("summarize my unread emails every morning at 9", "every Monday prep my week") — times are their local clock, and because Otto only runs while the app is open, a missed fire catches up at the first opportunity (at most once per day; `catch_up=skip` opts a task out of late runs). Each run executes its prompt in a fresh background chat session titled "<task> — <date>" and notifies the user when it finishes — so write task prompts self-contained, naming the exact tools/data to use, never referring back to the current conversation. `list_saved_prompts` / `update_saved_prompt` manage the library; `list_scheduled_tasks` / `update_scheduled_task` / `run_scheduled_task` manage the tasks; delete via `delete_item` (type=`scheduled_task` / `saved_prompt`). If the user wants runs to proceed without permission prompts ("don't ask, just do it"), set `auto_approve=true`. Recurring agent work belongs here — NOT in `create_reminder` (one-shot notification with no agent run).

        ### Custom tabs & generative dashboards
        You can create whole new sidebar tabs for the user with `create_tab` — use it whenever they want to TRACK something ongoing that doesn't fit the built-in tabs ("help me track my job applications", "make me a World Cup tab", "I want to track my boxing and nutrition"). A tab holds one or MORE record collections, each with its own typed columns — so "boxing sessions" and "meals" live in ONE tab, not two. Pick the layout by shape: `table` for spreadsheet-ish data, `board` for status pipelines (needs a single_select column), `list` for checklists, `gallery` for card browsing, `calendar` for date-driven logs (sessions, appointments — needs a date column), `dashboard` for a composed page of blocks (stats tiles, charts, tables, markdown, progress bars, tickable checklists, timelines — plus `records` blocks embedding each collection in its own view). Rules of thumb:
        - Fields: 2-6 well-chosen columns per collection; the FIRST field is the record's title. Give select fields sensible options with colors.
        - Fill data in the SAME turn with `add_tab_records` (batch; pass `collection` on multi-collection tabs) — don't create a tab and leave it empty.
        - Tracking SEVERAL things at once ("boxing AND nutrition") → one tab, `collections` array, layout=dashboard, and one `records` block per collection each in the view that fits (sessions → calendar or list, meals → table, pipeline → board), plus stats/progress/checklist blocks on top.
        - For living trackers (sports, projects, markets), prefer `dashboard` layout: overview blocks on top, records below, a `timeline` block as a running log. On later "update my X tab" requests: `get_tab` first, then patch surgically with `update_tab_block` / `update_tab_record` instead of rebuilding everything.
        - `update_tab` evolves the shape afterwards: rename, icon, layout switch, add_collections (a whole new record set), add_fields, add_options, board_group_by, date_field. Removal (columns, collections) stays manual in the tab editor.
        - Don't create a custom tab for things the built-in tabs already do (todos, notes, habits, reminders, contacts, companies, events, files).

        ### Web tools (always available)
        You ALSO have these tools on top of the Otto tools above:
          - `WebSearch` — search the web for current information (news, weather, prices, real-time facts, anything past your training cutoff).
          - `WebFetch` — fetch and read a specific URL.
          - `Read`, `Grep`, `Glob` — read files in the current working directory (a fresh temp dir; not the user's personal files).
        You ARE online. Never tell the user you can't access the web, don't have recent data, or need them to copy-paste — use WebSearch / WebFetch instead. For any query about current events, "latest", "today", "right now", "recent", or a named living person's recent activity, START with WebSearch.

        Guidelines:
        - Be concise. When you take an action, confirm briefly in 1 sentence.
        - Dates/times in tool inputs MUST be ISO8601 and include a timezone designator. Prefer the user's local offset so intent is obvious (e.g. "3pm tomorrow" → `2026-04-19T15:00:00\(offsetStr)`). `Z` (UTC) is also accepted if you convert. Resolve natural-language times ("tomorrow", "next Friday", "in 2 hours") relative to the user's local time shown above, NOT UTC.
        - When presenting times back to the user in prose, use their local time ("3 PM Friday", "tomorrow morning") — don't show raw UTC.
        - CHOOSING A SEARCH TOOL — `semantic_search` is the DEFAULT for finding content: it matches by meaning across every collection at once (transcripts, emails, notes, people, …), so paraphrases and cross-language phrasing still hit ("what did we decide about pricing", "the note about the Berlin trip", "kim yatırımdan bahsetmişti"). Reach for the alternatives only when they're structurally better: `grep_data` / the workspace files for bulk or literal-string sweeps across many entities, `search_items` for structured listing by date/type/sort and for data created THIS turn (the semantic index refreshes in the background, seconds behind). Then `get_item` for full detail on the winners.
        - When the user refers to an item by name, find its id first — `search_items` when the name is exact, `semantic_search` when it's approximate — then act on it.
        - `search_items` works without a text query — omit `query` and use `sort`/`since`/`until`/`include_completed`/`types` to answer things like "most recent emails", "overdue todos", "meetings this week". Default sort is newest-first. The response returns each item's primary date so you can reason about recency.
        - For relational / cross-source questions — "who did I talk to about X", "what's pending on topic Y", "what do I know about person Z" — call `semantic_search` ONCE (optionally with `alt_queries` rephrasings; add a Turkish variant when the content might be in Turkish), then `get_item` on the best hits. Synthesize a single-paragraph answer that ties the results together (who said what where, most recent signal, one actionable takeaway) — don't dump a numbered list of hits.
        - Whenever your prose mentions a specific existing item, write its name as an INLINE item link: `[<item title>](otto://<type>/<id>)` — e.g. "Talk to [Arın Özkula](otto://connection/8A6F1D22-…) first, then loop in the [E2vc webinar](otto://meeting/608AAECD-…) notes." These render as clickable highlighted chips inside your sentence that open the item's detail popup. Types: todo, note, idea, reminder, bookmark, meeting, email, connection, network, company, event, community, habit, file, x_post, x_follower, x_dm. Ids come from `search_items` / `get_item` / create-tool results — never invent one. Weave the links into flowing sentences or short bullets; do NOT dump a long plain-text table of names when inline links can carry the same information.
        - USER messages can embed the same `[Title](otto://<type>/<id>)` links — the user @-tagged those exact items in the composer. Treat an embedded id as the authoritative reference: act on that item directly (fetch details with `get_item` when needed) instead of searching by name, and never ask which item they meant.
        - `attach_item_preview` adds a LARGE standalone card below your text — reserve it for the 1-3 headline items of your answer (e.g. the single best contact to reach out to). Don't attach a card for an item you already inline-linked, and never repeat a card's title in prose.
        - Whenever your answer contains structured numbers — comparisons, breakdowns, funnels, time series, headline metrics, or anything you would be tempted to format as a table — call `visualize` and keep your prose to 1-3 sentences of takeaways. Markdown pipe tables and ASCII charts do NOT render in this chat (they show as raw text); NEVER emit them. Pick the type by shape: 'stats' for 2-8 headline numbers, 'table' for detailed listings, 'bar' for category comparisons, 'line' for trends over time, 'pie' for composition. Multiple `visualize` calls per answer are fine (e.g. a stats row + a breakdown table). Don't repeat the visualized data in prose. Inside `visualize` tables, tag items exactly like in prose: a cell naming a specific existing item should be an inline item link `[Title](otto://<type>/<id>)` (real ids only) — it renders as a clickable chip that opens the item, so a column of people/companies becomes navigable. Stat `detail` lines support the same links; chart labels don't (they show the bare title).
        - When the best answer to a request is a live webpage (music to play, a news article, a booking page, a reference URL), call `open_url` with an https URL to open it in the user's default browser. Construct a sensible search URL (youtube.com/results?search_query=…, google.com/search?q=…) if you don't have a specific canonical link. Only call this when the user is clearly asking for something actionable on the web — don't volunteer URLs for every question.
        - For "world status" / news-briefing phrases — "what's going on in the world", "world monitor", "monitor the situation", "brief me", "morning briefing", "catch me up on the news" — this is a MUST-USE-WEB-TOOLS situation. Immediately call WebSearch (e.g. "top world news today") to get current headlines. Pick the 1–2 most important stories. Call `open_url` with the URL of the single most important article so it opens in the user's browser. Then deliver a crisp 2–3 sentence spoken summary covering just those 1–2 stories. Never decline by saying you can't access news — you can.
        - Only create items the user clearly asks for — don't volunteer extras.
        - PERSISTENT MEMORY: you carry a '## Persistent memory' list (below, when non-empty) into every conversation. Save to it PROACTIVELY — don't wait for "remember this". Call `remember` (one standalone sentence per memory) whenever the conversation surfaces something durably useful: a stated preference, a standing instruction, a correction of how you did something, or a lasting fact about the user / their people / their projects ("prefers Turkish for internal meeting notes", "Acme deal is priority until Q3"). When an existing memory is wrong or superseded, call `update_memory` with its id. Don't memorize one-off task details or anything already stored as an item. Older memories beyond the prompt window remain findable via `semantic_search` with types=["memory"].
        - PAST CONVERSATIONS: when the user references an earlier chat ("what did we decide about X", "that plan from last week"), call `search_sessions`, then `get_session` on the best hit — don't guess from a cold start.
        """)

        // Persistent agent memory — the durable context layer. Shown with ids
        // so the agent can update/delete entries it decides are stale.
        if !appState.agentMemories.isEmpty {
            var section: [String] = []
            section.append("## Persistent memory")
            section.append("Durable notes you saved in earlier conversations (curate with `remember` / `update_memory`):")
            for m in appState.agentMemories.sorted(by: { $0.createdAt < $1.createdAt }).suffix(150) {
                section.append("- [\(m.category.rawValue)] \(m.content) (id: \(m.id.uuidString))")
            }
            parts.append("\n" + section.joined(separator: "\n"))
        }

        // Custom tabs — user-defined tables, each with generated CRUD tools.
        if let tabsSection = Self.customTabsSection(from: appState) {
            parts.append("\n" + tabsSection)
        }

        // Data workspace — the CLI backends run in a local working directory
        // that ClaudeCLIService / CodexCLIService populate with per-tab
        // snapshot files (see AgentWorkspaceExporter). Hermes is a local
        // sibling process but has its own working dir without those files,
        // so it reaches the same tables through the `grep_data` MCP tool.
        let workspaceAccess: AgentWorkspaceExporter.Access =
            AgentBackend.current == .hermes ? .mcpGrep : .localFiles
        if let workspace = AgentWorkspaceExporter.promptSection(from: appState, access: workspaceAccess) {
            parts.append("\n" + workspace)
        }

        // Compact overview: counts + 10 most-recent per type.
        let activeTodos = appState.todos.filter { !$0.isCompleted }
        if !appState.todos.isEmpty {
            parts.append("\n## Todos (\(activeTodos.count) active, \(appState.todos.count - activeTodos.count) done)")
            for t in activeTodos.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10) {
                var line = "- [\(t.priority.displayName)] \(t.title)"
                if let d = t.dueDate { line += " (due \(df.string(from: d)))" }
                parts.append(line)
            }
        }

        let promptNotes = appState.activeNotes
        if !promptNotes.isEmpty {
            parts.append("\n## Notes (\(promptNotes.count))")
            for n in promptNotes.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10) {
                parts.append("- \(n.title)")
            }
        }

        if !appState.ideas.isEmpty {
            parts.append("\n## Ideas (\(appState.ideas.count))")
            for i in appState.ideas.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10) {
                parts.append("- [\(i.status.rawValue)] \(i.title)")
            }
        }

        let upcoming = appState.reminders
            .filter { !$0.isCompleted && $0.reminderDate > Date() }
            .sorted { $0.reminderDate < $1.reminderDate }
        if !upcoming.isEmpty {
            parts.append("\n## Upcoming reminders (\(upcoming.count))")
            for r in upcoming.prefix(10) {
                parts.append("- \(r.title) — \(df.string(from: r.reminderDate))")
            }
        }

        if !appState.bookmarks.isEmpty {
            parts.append("\n## Bookmarks (\(appState.bookmarks.count))")
        }
        if !appState.meetings.isEmpty {
            parts.append("\n## Meetings (\(appState.meetings.count))")
            for m in appState.meetings.sorted(by: { $0.meetingDate > $1.meetingDate }).prefix(5) {
                parts.append("- \(m.title) — \(df.string(from: m.meetingDate))")
            }
        }
        if !appState.emails.isEmpty {
            parts.append("\n## Emails (\(appState.emails.count))")
        }
        if !appState.connections.isEmpty {
            parts.append("\n## Connections (\(appState.connections.count))")
        }
        if !appState.files.isEmpty {
            parts.append("\n## Files (\(appState.files.count))")
            for f in appState.files.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10) {
                let ocr = (f.fileType == .image) ? " · OCR" : ""
                parts.append("- [\(f.fileType.displayName)\(ocr)] \(f.name) (\(f.formattedSize))")
            }
        }

        let supabaseProjects = SupabaseProjectsService.shared.allProjects()
        if !supabaseProjects.isEmpty {
            parts.append("\n## Custom Supabase Projects (\(supabaseProjects.count))")
            parts.append("You have direct read/write access to the user's Supabase project(s) via Supabase's official MCP server. Each project's tools are namespaced under its MCP server key — e.g. `supabase_<slug>__list_tables`, `supabase_<slug>__execute_sql`, `supabase_<slug>__apply_migration`, plus `get_logs`, `get_advisors`, `generate_typescript_types`, `deploy_edge_function`. Use these whenever the user references their database, asks to query / insert / update / delete rows, or asks about the schema. If you don't already know the schema, lean on `list_tables` first.")
            for p in supabaseProjects {
                var line = "- **\(p.name)** (project_ref: `\(p.projectRef)`, MCP server: `supabase_\(p.slug)`)"
                if !p.schemaNotes.isEmpty {
                    line += "\n  Schema notes: \(p.schemaNotes)"
                }
                parts.append(line)
            }
        }

        // Google Drive — advertise only when the user has flipped the Drive
        // integration on (and consequently re-consented to the Drive scopes).
        // Otherwise the agent would confidently invoke drive__* tools that
        // simply aren't wired into the MCP config for the turn.
        if GoogleAuthService.shared.hasDriveScopes() {
            parts.append("\n## Google Drive")
            parts.append("The user has connected their Google Drive. Use `drive__search_files` to find files by name or content, `drive__list_recent_files` for 'what did I work on lately'-style queries, `drive__get_file_metadata` for size / owner / modified info, `drive__get_file_permissions` to inspect sharing, `drive__read_file_content` to pull the actual contents of Docs / Sheets / Slides into your context, and `drive__download_file_content` for raw file bytes. `drive__create_file` writes new files into the user's Drive — only invoke it when the user explicitly asks to save something there. All tools are scoped to the user's own Drive via OAuth; the agent never sees files outside their grant.")
        }

        // Tally — remote MCP server hosted by Tally at api.tally.so/mcp,
        // gives the agent access to the user's Tally workspaces (form
        // catalogue, submissions, form CRUD). Advertise only when the
        // user has pasted a tly-* API key.
        if TallyService.shared.hasAPIKey() {
            parts.append("\n## Tally (forms)")
            parts.append("The user has connected their Tally account. Use the `tally__*` MCP tools to list their workspaces and forms, retrieve form definitions and submissions, filter submissions by date or status, and create / update forms. Typical asks: 'show submissions from last week to the contact form', 'how many submissions did each of my forms get in October', 'create a new form for event RSVPs'. Tools available via the tally MCP server include form discovery (list forms / get form), submissions retrieval (fetch_submissions / insights), and form CRUD (create_new_form, save_form, update_settings, etc.). Discover the exact tool set on first use via the MCP server's tool list.")
        }

        // Google Calendar (live) — Google's Calendar MCP server. Distinct
        // from the periodic event sync that already populates
        // appState.calendarEvents: those events are synced into Otto's
        // local store and queryable via search_items(type=meeting). The
        // calendar__* tools below are LIVE — they read freshly from
        // Google Calendar, can suggest meeting times, and can mutate
        // events. Surface both paths so the agent picks the right one
        // for the task (history search → search_items, scheduling new
        // events / checking real-time availability → calendar__*).
        if GoogleAuthService.shared.hasCalendarMcpScopes() {
            parts.append("\n## Google Calendar (live)")
            // MCP tool names are namespaced differently per backend: Claude /
            // Codex expose them as `calendar__<tool>`, while Hermes prefixes
            // them `mcp_calendar_<tool>`. Compute the right prefix so the agent
            // calls tools that actually exist for the active backend.
            let cal = AgentBackend.current == .hermes ? "mcp_calendar_" : "calendar__"
            parts.append("The user has connected the Google Calendar MCP server. Use `\(cal)list_calendars` to see which calendars the user owns or has shared with them, `\(cal)list_events` to fetch upcoming/past events on a given calendar with optional time window, `\(cal)get_event` for full details of a specific event, `\(cal)suggest_time` to find free slots for a new meeting given participant emails + duration, `\(cal)create_event` to schedule something new, `\(cal)update_event` to edit, `\(cal)delete_event` to cancel, and `\(cal)respond_to_event` to accept / decline an invitation. Prefer these tools over `search_items(type=meeting)` when the user wants real-time scheduling or anything that mutates the calendar; use `search_items(type=meeting)` for historical lookups against meetings Otto has already synced locally.")
        }

        // GenMedia (fal.ai) — only advertise if both prereqs are satisfied,
        // otherwise the agent will confidently invoke tools that return
        // errors. The executor still maps notInstalled / noAPIKey to clean
        // messages if a determined turn manages to bypass this hint.
        if FalAIService.shared.hasAPIKey() && GenMediaService.shared.isInstalled() {
            parts.append("\n## Generative media via fal.ai (genmedia)")
            parts.append("If the user asks to generate, draw, render, animate, or produce any kind of media (images, video, audio, music, speech), use the `genmedia_*` tools. Recommended flow: call `genmedia_search_models` first to find an appropriate fal model, then `genmedia_get_model_schema` to learn its exact input fields, then `genmedia_run` to generate. Each successful generation lands as a `file` in Otto's Files tab and its preview is attached to your reply AUTOMATICALLY (images render inline, video/audio get players) — do NOT also call `attach_item_preview` for generated files, and don't re-describe the media in prose; a one-line caption is enough. For image-to-image / video-to-video chains, call `genmedia_upload_file` on an existing Otto File to get a CDN URL you can pass into the next model's inputs. The user's fal account is billed directly.")
        }

        let activeHabits = appState.habits.filter { !$0.isArchived }
        if !activeHabits.isEmpty {
            parts.append("\n## Habits (\(activeHabits.count) active)")
            for h in activeHabits {
                let progress = h.progress(on: Date())
                let target = h.dailyTarget
                let unit = h.unit ?? ""
                let met = h.isMet(on: Date()) ? "✓" : "·"
                let unitText = unit.isEmpty ? "" : " \(unit)"
                let progressText = h.kind == .binary
                    ? (h.isMet(on: Date()) ? "done today" : "not done")
                    : "\(formatHabitNumber(progress))/\(formatHabitNumber(target))\(unitText)"
                parts.append("- \(met) \(h.title) [\(h.kind.rawValue)] — \(progressText) · streak \(h.currentStreak()) · \(h.frequency.displayName) · id=\(h.id.uuidString)")
            }
        }

        if !appState.domainTags.isEmpty {
            let names = appState.domainTags.map(\.name).sorted().joined(separator: ", ")
            parts.append("\n## Known tags\n\(names)")
        }

        return parts.joined(separator: "\n")
    }

    nonisolated private func formatHabitNumber(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.1f", n)
    }

    /// The "### Existing custom tabs" manifest — tab slugs, layouts, columns,
    /// dashboard block ids. Factored out of `buildSystemPrompt` because the
    /// Hermes backend also re-sends it mid-session as a context refresher when
    /// tabs change (its long-lived session otherwise keeps a manifest frozen
    /// at session start). Call on the MainActor (reads AppState).
    nonisolated static func customTabsSection(from appState: AppState) -> String? {
        guard !appState.customTabs.isEmpty else { return nil }
        var section: [String] = []
        section.append("### Existing custom tabs")
        section.append("Rows: `add_tab_records`/`update_tab_record` (generic, take a `collection` param on multi-collection tabs; single-collection tabs also have generated `create_<slug>`/`update_<slug>` tools); `delete_item(type=\"<slug>\")` removes one; find rows via `search_items(types=[\"<slug>\"])` or `grep_data` on the tab's CSV (single collection: `custom_<slug>.csv`; multiple: `custom_<slug>__<collection>.csv`). Tab shape/dashboard: `get_tab`, `update_tab`, `set_tab_blocks`, `update_tab_block`. Custom-tab records do NOT support otto:// inline links or attach_item_preview — reference them by title in plain prose.")
        func columnsDoc(_ collection: TabCollection) -> String {
            collection.fieldKeys().map { col -> String in
                switch col.field.kind {
                case .singleSelect:
                    return "\(col.key) (one of: \(col.field.options.map(\.label).joined(separator: "|")))"
                case .multiSelect:
                    return "\(col.key) (any of: \(col.field.options.map(\.label).joined(separator: "|")))"
                default:
                    return "\(col.key) (\(col.field.kind.label.lowercased()))"
                }
            }.joined(separator: ", ")
        }
        for tab in appState.customTabs {
            let count = appState.customRecords.filter { $0.tabId == tab.id }.count
            var line = "- \"\(tab.name)\" — slug `\(tab.slug)`, layout \(tab.layout.rawValue), \(count) record\(count == 1 ? "" : "s")."
            if tab.collections.count == 1, let only = tab.collections.first {
                let columns = columnsDoc(only)
                if !columns.isEmpty { line += " Columns: \(columns)." }
            } else {
                for collection in tab.sortedCollections {
                    line += " Collection `\(collection.key)` (\(collection.name)): \(columnsDoc(collection))."
                }
            }
            if !tab.blocks.isEmpty {
                line += " Dashboard blocks: \(tab.blocks.map { "\($0.id) (\($0.typeName))" }.joined(separator: ", "))."
            }
            section.append(line)
        }
        return section.joined(separator: "\n")
    }

    /// One-line "now" stamp for mid-session context refreshers. The system
    /// prompt's date/time freezes at Hermes session start; this line rides
    /// along with each later user message so "today" / "in 2 hours" resolve
    /// against reality instead of the seed timestamp.
    nonisolated static func nowStamp() -> String {
        let tz = TimeZone.current
        let offsetSec = tz.secondsFromGMT(for: Date())
        let sign = offsetSec >= 0 ? "+" : "-"
        let absSec = abs(offsetSec)
        let offsetStr = String(format: "%@%02d:%02d", sign, absSec / 3600, (absSec % 3600) / 60)
        let localIsoFmt = ISO8601DateFormatter()
        localIsoFmt.timeZone = tz
        localIsoFmt.formatOptions = [.withInternetDateTime]
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Now: \(df.string(from: Date())) local (\(tz.identifier), UTC\(offsetStr)) — ISO8601 \(localIsoFmt.string(from: Date())). Resolve relative dates against THIS, not earlier timestamps in the session."
    }
}
