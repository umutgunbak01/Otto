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
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],
        executor: OttoToolExecutor,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {
        return try await streamChatWithTools(
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
    func streamChatWithTools(
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
                turns: turns,
                systemPrompt: systemPrompt,
                tools: tools,
                executor: executor,
                onDelta: onDelta,
                onEvent: onEvent
            )
        case .codex:
            return try await CodexCLIService.shared.streamChatWithTools(
                turns: turns,
                systemPrompt: systemPrompt,
                tools: tools,
                executor: executor,
                onDelta: onDelta,
                onEvent: onEvent
            )
        }
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

        You have tools to create / update / complete / delete / search the user's items (todos, notes, ideas, reminders, bookmarks, meetings, emails, connections, habits, **files** — user-imported PDFs / CSVs / images / text). Use tools whenever the user asks you to change state or find specific items. For open-ended questions, answer using the overview below plus `search_items` / `get_item` when you need detail.

        ### Files
        The user can import PDFs, CSVs, Excel sheets, images (PNG/JPG/HEIC — OCR'd at import), and plain-text formats (txt/md/json/yaml/log/html/xml/rtf) via the Files tab. To work with them: call `search_items` with `types=["file"]` (and optionally a `query`) to discover ids and names; call `read_file` with an id to get the extracted text plus an absolute path on disk. For images where OCR'd text isn't enough, or for PDFs with patchy extraction, ALSO call the built-in `Read` tool on the returned path — Claude Code's Read is multimodal and can see the image directly. When the user says "open the spreadsheet I uploaded", "what did the invoice say", "summarize that PDF", "find the file about X" — start with `search_items` (type=file), not WebSearch.

        ### Habits
        The user tracks habits in the Habits tab. Use `create_habit` when the user describes a routine they want to build ("I want to drink 2.5L of water every day", "track no porn", "log my workouts 3x a week"). Infer the right shape from their words: numeric amounts with units → `kind=quantity` (e.g. 2500 mL water), time-based → `kind=duration` (e.g. 30 min reading), simple done/not-done → `kind=binary`. Use `log_habit_entry` when the user reports doing some amount ("I drank 500ml", "read for 25 min", "did 30 pushups", "ate 80g of protein") — you can pass the habit name and the executor will find it. Use `complete_habit` when they finished a habit with no specific quantity ("done with my workout", "meditated today", "made my bed"). Use `list_habits` for "how am I doing today?" / "what habits did I miss?" before answering.

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
        - When the user refers to an item by name, use `search_items` first to find its id, then act on it.
        - `search_items` works without a text query — omit `query` and use `sort`/`since`/`until`/`include_completed`/`types` to answer things like "most recent emails", "overdue todos", "meetings this week". Default sort is newest-first. The response returns each item's primary date so you can reason about recency.
        - For relational / cross-source questions — "who did I talk to about X", "what's pending on topic Y", "what do I know about person Z" — call `search_items` ONCE with `types` spanning multiple sources (typical combo: `["email", "meeting", "note", "connection"]`) and a `query` string. Then synthesize a single-paragraph answer that ties the results together (who said what where, most recent signal, one actionable takeaway) — don't dump a numbered list of hits.
        - Whenever your answer references a specific existing item (todo, note, idea, reminder, bookmark, meeting, email, or connection), call `attach_item_preview` with its id and type so the user gets a clickable card instead of a plain-text name. One card per item; call the tool multiple times for multiple items. Do NOT also repeat the item title in prose — the card shows it.
        - When the best answer to a request is a live webpage (music to play, a news article, a booking page, a reference URL), call `open_url` with an https URL to open it in the user's default browser. Construct a sensible search URL (youtube.com/results?search_query=…, google.com/search?q=…) if you don't have a specific canonical link. Only call this when the user is clearly asking for something actionable on the web — don't volunteer URLs for every question.
        - For "world status" / news-briefing phrases — "what's going on in the world", "world monitor", "monitor the situation", "brief me", "morning briefing", "catch me up on the news" — this is a MUST-USE-WEB-TOOLS situation. Immediately call WebSearch (e.g. "top world news today") to get current headlines. Pick the 1–2 most important stories. Call `open_url` with the URL of the single most important article so it opens in the user's browser. Then deliver a crisp 2–3 sentence spoken summary covering just those 1–2 stories. Never decline by saying you can't access news — you can.
        - Only create items the user clearly asks for — don't volunteer extras.
        """)

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

        if !appState.notes.isEmpty {
            parts.append("\n## Notes (\(appState.notes.count))")
            for n in appState.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10) {
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
}
