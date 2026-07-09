import Foundation

/// Catalogue of tools exposed to Claude for unified Home input.
/// Each entry is a dictionary directly serializable to the Anthropic `tools` array.
enum OttoTools {

    /// Compile-time set of tool names. Executor switches on these.
    enum Name: String {
        case create_todo, create_note, create_idea, create_reminder, create_bookmark, create_meeting
        case update_todo, update_note, update_idea, update_reminder, update_bookmark, update_meeting
        case create_network_entry, update_network_entry
        case create_company, update_company
        case create_event, update_event
        case create_community, update_community
        case complete_todo, uncomplete_todo, complete_reminder
        case delete_item
        case search_items, grep_data, get_item
        case attach_item_preview
        case visualize
        case open_url
        case create_habit, log_habit_entry, complete_habit, list_habits, update_habit
        case read_file
        case create_file
        case genmedia_search_models, genmedia_get_model_schema, genmedia_run, genmedia_upload_file
    }

    // MARK: - Backend-agnostic name / preview helpers
    //
    // Tool calls reach the chat UI under different names depending on the
    // backend: the direct API path uses the bare `Name` (e.g.
    // "attach_item_preview"), while MCP clients (Hermes over ACP) announce
    // the same tool as `mcp__otto__attach_item_preview`. These helpers give
    // every consumer one canonical view.

    /// Strip an MCP client's `mcp__<server>__` prefix from a tool name so
    /// callers can match against the bare `OttoTools.Name`.
    static func canonicalToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mcp__") else { return trimmed }
        let rest = trimmed.dropFirst("mcp__".count)
        guard let sep = rest.range(of: "__") else { return trimmed }
        return String(rest[sep.upperBound...])
    }

    /// True when `raw` names the attach_item_preview tool under any backend's
    /// naming — bare, MCP-prefixed, or humanized ("Attach Item Preview").
    static func isAttachItemPreview(_ raw: String) -> Bool {
        let normalized = canonicalToolName(raw)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.hasSuffix(Name.attach_item_preview.rawValue)
    }

    /// True when `raw` names the visualize tool under any backend's naming —
    /// bare, MCP-prefixed, or humanized ("Visualize").
    static func isVisualize(_ raw: String) -> Bool {
        let normalized = canonicalToolName(raw)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.hasSuffix(Name.visualize.rawValue)
    }

    /// Map the tool schema's snake_case `type` strings onto `ContentType`,
    /// whose raw values are camelCase for the multi-word cases.
    static func previewContentType(_ raw: String) -> ContentType? {
        switch raw {
        case "network":    return .networkHub
        case "x_post":     return .xPost
        case "x_follower": return .xFollower
        case "x_dm":       return .xDm
        default:           return ContentType(rawValue: raw)
        }
    }

    /// True when `raw` names the create_file tool under any backend's
    /// naming — bare, MCP-prefixed, or humanized ("Create File").
    static func isCreateFile(_ raw: String) -> Bool {
        let normalized = canonicalToolName(raw)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.hasSuffix(Name.create_file.rawValue)
    }

    /// Recover the new file's id from the executor's
    /// "Created file: <uuid> — <filename> (<size>)" result line, so the chat
    /// can auto-attach a downloadable file card without relying on the agent
    /// to call attach_item_preview.
    static func parseCreatedFileResult(_ text: String) -> UUID? {
        guard let marker = text.range(of: "Created file: ") else { return nil }
        let token = text[marker.upperBound...]
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
        return token.flatMap { UUID(uuidString: String($0)) }
    }

    /// Recover `(type, id)` from the executor's
    /// "Attached preview: <type> <uuid> — <title>" result line. Used when a
    /// backend doesn't deliver tool inputs (ACP tool_call without rawInput),
    /// so the preview card can still be built from the tool result.
    static func parsePreviewResult(_ text: String) -> (typeString: String, id: UUID)? {
        guard let marker = text.range(of: "Attached preview: ") else { return nil }
        let tokens = text[marker.upperBound...]
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard tokens.count >= 2, let id = UUID(uuidString: String(tokens[1])) else { return nil }
        return (String(tokens[0]), id)
    }

    /// Parse an inline item-reference URL the agent embeds in its prose:
    /// `otto://<type>/<uuid>` (type uses the tool schema's snake_case names).
    /// The chat renderer styles these markdown links as clickable chips that
    /// open the item's detail popup. Parsed by hand rather than via URL
    /// host/path because Foundation is picky about underscores in hostnames
    /// (`x_post`).
    static func parseItemURL(_ url: URL) -> (type: ContentType, id: UUID)? {
        guard url.scheme?.lowercased() == "otto" else { return nil }
        let rest = url.absoluteString.dropFirst("otto://".count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let type = previewContentType(String(parts[0]).lowercased()),
              let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        return (type, id)
    }

    /// Static catalogue (no custom tabs). Prefer `catalog(customTabs:)`
    /// anywhere AppState is reachable so user-defined tabs get their
    /// generated tools; kept for call sites whose `tools:` parameter the
    /// backends ignore anyway (tools flow through the MCP server).
    static var all: [[String: Any]] { catalog(customTabs: []) }

    /// Full tool catalogue: the built-in tools (with custom-tab slugs spliced
    /// into the delete/search/get type enums) plus a generated
    /// `create_<slug>` / `update_<slug>` pair per custom tab.
    static func catalog(customTabs: [CustomTabDefinition]) -> [[String: Any]] {
        var out = baseTools(customTypeSlugs: customTabs.map(\.slug))
        for tab in customTabs {
            out.append(createTool(for: tab))
            out.append(updateTool(for: tab))
        }
        return out
    }

    /// The built-in tool definitions. `customTypeSlugs` extends the item-type
    /// enums so `delete_item` / `search_items` / `get_item` accept custom-tab
    /// records too.
    private static func baseTools(customTypeSlugs: [String]) -> [[String: Any]] {
        return [
        // MARK: Create
        [
            "name": Name.create_todo.rawValue,
            "description": "Create a new todo/task. Use when the user asks to add, remember, or schedule a task.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("The task title (required)."),
                    "description": stringProp("Optional extra detail."),
                    "priority": enumProp(["low", "medium", "high", "urgent"], "Priority; defaults to medium."),
                    "due_date": stringProp("ISO8601 datetime, e.g. 2026-04-19T17:00:00Z."),
                    "tags": arrayOfStrings("Domain tag names.")
                ],
                required: ["title"]
            )
        ],
        [
            "name": Name.create_note.rawValue,
            "description": "Create a note. Use when the user wants to jot down information or thoughts.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("Note title."),
                    "content": stringProp("Note body (plain text)."),
                    "category": enumProp(["work", "personal", "hobby"], "Primary category; defaults to personal."),
                    "tags": arrayOfStrings("Domain tag names.")
                ],
                required: ["title"]
            )
        ],
        [
            "name": Name.create_idea.rawValue,
            "description": "Create an idea. Use when the user expresses a potential project, theory, or thing to explore.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("Idea title."),
                    "content": stringProp("Idea body."),
                    "category": enumProp(["work", "personal", "hobby"], "Primary category; defaults to personal."),
                    "tags": arrayOfStrings("Domain tag names.")
                ],
                required: ["title"]
            )
        ],
        [
            "name": Name.create_reminder.rawValue,
            "description": "Create a time-based reminder. Use for 'remind me to…' phrasing with a specific time.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("What to be reminded of."),
                    "reminder_date": stringProp("ISO8601 datetime when to fire, e.g. 2026-04-19T17:00:00Z.")
                ],
                required: ["title", "reminder_date"]
            )
        ],
        [
            "name": Name.create_bookmark.rawValue,
            "description": "Save a URL as a bookmark.",
            "input_schema": objectSchema(
                properties: [
                    "url": stringProp("The URL to save."),
                    "title": stringProp("Optional title; inferred from URL if omitted."),
                    "description": stringProp("Optional description.")
                ],
                required: ["url"]
            )
        ],
        [
            "name": Name.create_meeting.rawValue,
            "description": "Create a meeting note. Use when the user wants to record a meeting they had or plan to have — capturing notes, a summary, action items, and participants. Distinct from a plain note because meetings have structured fields the Meetings tab renders (overview card, action items list, participant chips). For a one-off thought with no meeting context, prefer `create_note` instead.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("Meeting title (required)."),
                    "content": stringProp("Full notes / transcript body. Plain text or markdown."),
                    "overview": stringProp("Short summary of what was discussed; shown at the top of the meeting card."),
                    "action_items": stringProp("Action items / follow-ups, one per line. Plain text."),
                    "participants": arrayOfStrings("Names or emails of people who attended."),
                    "organizer": stringProp("Name or email of who organized the meeting."),
                    "duration_minutes": ["type": "integer", "description": "Length of the meeting in minutes. Optional.", "minimum": 0],
                    "meeting_date": stringProp("ISO8601 datetime when the meeting happened or will happen, e.g. 2026-05-19T15:00:00Z. Defaults to now."),
                    "tags": arrayOfStrings("Domain tag names.")
                ],
                required: ["title"]
            )
        ],

        // MARK: Update
        [
            "name": Name.update_todo.rawValue,
            "description": "Update fields on an existing todo. Only include fields you want to change.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the todo."),
                    "title": stringProp(""),
                    "description": stringProp(""),
                    "priority": enumProp(["low", "medium", "high", "urgent"], ""),
                    "due_date": stringProp("ISO8601 datetime, or empty string to clear.")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.update_note.rawValue,
            "description": "Update a note's title or content.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the note."),
                    "title": stringProp(""),
                    "content": stringProp("")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.update_idea.rawValue,
            "description": "Update an idea's title, content, or status.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the idea."),
                    "title": stringProp(""),
                    "content": stringProp(""),
                    "status": enumProp(["raw", "researched", "validated", "archived"], "")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.update_reminder.rawValue,
            "description": "Update a reminder's title or fire time. Use for 'push that to 6pm' / 'rename my reminder'. Rescheduling to a future time re-arms the notification.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the reminder."),
                    "title": stringProp(""),
                    "reminder_date": stringProp("New ISO8601 datetime when to fire, e.g. 2026-04-19T17:00:00Z.")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.update_bookmark.rawValue,
            "description": "Update fields on an existing bookmark. Only include fields you want to change.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the bookmark."),
                    "title": stringProp(""),
                    "url": stringProp(""),
                    "description": stringProp(""),
                    "media_type": enumProp(["read_later", "listen_later", "watch_later"], "Which queue the bookmark lives in."),
                    "is_read": ["type": "boolean", "description": "Mark the bookmark read (true) or unread (false)."]
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.update_meeting.rawValue,
            "description": "Update fields on an existing meeting note. Only include fields you want to change. `participants` replaces the whole list when provided.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the meeting."),
                    "title": stringProp(""),
                    "content": stringProp("Full notes / transcript body."),
                    "overview": stringProp("Short summary shown at the top of the meeting card."),
                    "action_items": stringProp("Action items / follow-ups, one per line."),
                    "participants": arrayOfStrings("Replaces the full participant list."),
                    "organizer": stringProp(""),
                    "duration_minutes": ["type": "integer", "description": "Meeting length in minutes.", "minimum": 0],
                    "meeting_date": stringProp("ISO8601 datetime.")
                ],
                required: ["id"]
            )
        ],

        // MARK: CRM — Network Hub / Companies / Events / Communities
        [
            "name": Name.create_network_entry.rawValue,
            "description": "Add a person or organization to the Network Hub (the curated people CRM, type=network). Use when the user meets someone new or wants a contact tracked. Provide at least a `name` or a `company`.",
            "input_schema": objectSchema(
                properties: [
                    "name": stringProp("Person's full name. May be empty for org-only entries that have a `company`."),
                    "company": stringProp("Company / organization the person belongs to (or the org itself)."),
                    "title": stringProp("Their role title, e.g. 'General Partner'."),
                    "type": enumProp(
                        ["startup", "investor", "app_studio", "enterprise", "media", "community", "incubator", "accelerator", "consulting", "ecosystem", "other"],
                        "Organization classification. Defaults to other."
                    ),
                    "individual_type": enumProp(
                        ["founder", "vc", "operator", "engineer", "community_builder", "angel_investor", "creative", "other"],
                        "The person's role bucket. Defaults to other."
                    ),
                    "industry": stringProp("Industry, e.g. 'AI infra', 'Fintech'."),
                    "location": stringProp("City / region, e.g. 'Barcelona'."),
                    "email": stringProp(""),
                    "linkedin": stringProp("LinkedIn profile URL."),
                    "closeness": enumProp(
                        ["close_friend", "warm_relationship", "known_personally", "intro_path_available", "light_connection", "unknown"],
                        "Relationship strength. Defaults to unknown."
                    ),
                    "notes": stringProp("Free-form notes — how you met, what they care about, follow-ups.")
                ],
                required: []
            )
        ],
        [
            "name": Name.update_network_entry.rawValue,
            "description": "Update fields on a Network Hub entry (type=network). Only include fields you want to change. The structured LinkedIn profile section (summary, experience, education) is import-managed and not editable here.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the network entry."),
                    "name": stringProp(""),
                    "company": stringProp(""),
                    "title": stringProp(""),
                    "type": enumProp(
                        ["startup", "investor", "app_studio", "enterprise", "media", "community", "incubator", "accelerator", "consulting", "ecosystem", "other"],
                        ""
                    ),
                    "individual_type": enumProp(
                        ["founder", "vc", "operator", "engineer", "community_builder", "angel_investor", "creative", "other"],
                        ""
                    ),
                    "industry": stringProp(""),
                    "location": stringProp(""),
                    "email": stringProp(""),
                    "linkedin": stringProp("LinkedIn profile URL. Empty string clears it."),
                    "closeness": enumProp(
                        ["close_friend", "warm_relationship", "known_personally", "intro_path_available", "light_connection", "unknown"],
                        ""
                    ),
                    "notes": stringProp("")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.create_company.rawValue,
            "description": "Add a company to the location CRM (type=company). Use for customers, prospects, or orgs worth tracking. Fails if a company with the same name already exists — update that one instead.",
            "input_schema": objectSchema(
                properties: [
                    "name": stringProp("Company name (required)."),
                    "type": enumProp(
                        ["startup", "scaleup", "enterprise", "vc", "agency", "research", "media", "other"],
                        "Company classification. Defaults to uncategorized."
                    ),
                    "location": stringProp("Free-text city/region; drives map placement, e.g. 'Barcelona'."),
                    "is_customer": ["type": "boolean", "description": "Whether they're a customer. Default false."],
                    "commitment_amount": ["type": "number", "description": "$ committed (revenue / deal size)."],
                    "website": stringProp(""),
                    "notes": stringProp(""),
                    "tags": arrayOfStrings(""),
                    "linked_network_entry_ids": arrayOfStrings("UUIDs of Network Hub people to link to this company (from search_items type=network).")
                ],
                required: ["name"]
            )
        ],
        [
            "name": Name.update_company.rawValue,
            "description": "Update fields on a company. Only include fields you want to change. `tags` and `linked_network_entry_ids` replace the whole list when provided; commitment_amount of 0 clears it.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the company."),
                    "name": stringProp(""),
                    "type": enumProp(
                        ["startup", "scaleup", "enterprise", "vc", "agency", "research", "media", "other"],
                        ""
                    ),
                    "location": stringProp(""),
                    "is_customer": ["type": "boolean"],
                    "commitment_amount": ["type": "number", "description": "$ committed. Pass 0 to clear."],
                    "website": stringProp("Empty string clears it."),
                    "notes": stringProp(""),
                    "tags": arrayOfStrings("Replaces the full tag list."),
                    "linked_network_entry_ids": arrayOfStrings("Replaces the full linked-people list.")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.create_event.rawValue,
            "description": "Add an event to the location CRM (type=event) — conferences, summits, dinners the user is hosting, attending, or considering.",
            "input_schema": objectSchema(
                properties: [
                    "name": stringProp("Event name (required)."),
                    "type": enumProp(
                        ["conference", "summit", "meetup", "hackathon", "dinner", "workshop", "party", "other"],
                        "Kind of event. Defaults to uncategorized."
                    ),
                    "location": stringProp("Free-text city/region; drives map placement."),
                    "start_date": stringProp("ISO8601 date or datetime, e.g. 2026-09-14."),
                    "end_date": stringProp("ISO8601 date or datetime. Omit for single-day events."),
                    "status": enumProp(
                        ["considering", "attending", "hosting", "declined"],
                        "The user's relationship to the event. Defaults to considering."
                    ),
                    "budget_amount": ["type": "number", "description": "$ budget / sponsorship."],
                    "notes": stringProp(""),
                    "tags": arrayOfStrings("")
                ],
                required: ["name"]
            )
        ],
        [
            "name": Name.update_event.rawValue,
            "description": "Update fields on an event. Only include fields you want to change. Empty string on start_date/end_date clears the date; budget_amount of 0 clears it; `tags` replaces the whole list.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the event."),
                    "name": stringProp(""),
                    "type": enumProp(
                        ["conference", "summit", "meetup", "hackathon", "dinner", "workshop", "party", "other"],
                        ""
                    ),
                    "location": stringProp(""),
                    "start_date": stringProp("ISO8601, or empty string to clear."),
                    "end_date": stringProp("ISO8601, or empty string to clear."),
                    "status": enumProp(["considering", "attending", "hosting", "declined"], ""),
                    "budget_amount": ["type": "number", "description": "$ budget. Pass 0 to clear."],
                    "notes": stringProp(""),
                    "tags": arrayOfStrings("Replaces the full tag list.")
                ],
                required: ["id"]
            )
        ],
        [
            "name": Name.create_community.rawValue,
            "description": "Add a community / society / accelerator to the location CRM (type=community). Fails if one with the same name already exists — update that one instead.",
            "input_schema": objectSchema(
                properties: [
                    "name": stringProp("Community name (required)."),
                    "type": enumProp(
                        ["community", "society", "collective", "accelerator", "dao", "other"],
                        "Kind of community. Defaults to community."
                    ),
                    "location": stringProp("Free-text city/region; drives map placement."),
                    "builder_support_perk": ["type": "boolean", "description": "Whether it offers a perk for builders. Default false."],
                    "url": stringProp("Website / community link."),
                    "notes": stringProp(""),
                    "tags": arrayOfStrings("")
                ],
                required: ["name"]
            )
        ],
        [
            "name": Name.update_community.rawValue,
            "description": "Update fields on a community. Only include fields you want to change. `tags` replaces the whole list when provided.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the community."),
                    "name": stringProp(""),
                    "type": enumProp(["community", "society", "collective", "accelerator", "dao", "other"], ""),
                    "location": stringProp(""),
                    "builder_support_perk": ["type": "boolean"],
                    "url": stringProp("Empty string clears it."),
                    "notes": stringProp(""),
                    "tags": arrayOfStrings("Replaces the full tag list.")
                ],
                required: ["id"]
            )
        ],

        // MARK: Complete / toggle
        [
            "name": Name.complete_todo.rawValue,
            "description": "Mark a todo as completed.",
            "input_schema": objectSchema(
                properties: ["id": stringProp("UUID of the todo.")],
                required: ["id"]
            )
        ],
        [
            "name": Name.uncomplete_todo.rawValue,
            "description": "Mark a todo as not completed.",
            "input_schema": objectSchema(
                properties: ["id": stringProp("UUID of the todo.")],
                required: ["id"]
            )
        ],
        [
            "name": Name.complete_reminder.rawValue,
            "description": "Mark a reminder as completed.",
            "input_schema": objectSchema(
                properties: ["id": stringProp("UUID of the reminder.")],
                required: ["id"]
            )
        ],

        // MARK: Delete
        [
            "name": Name.delete_item.rawValue,
            "description": "Delete an item of the given type.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the item."),
                    "type": enumProp(
                        ["todo", "note", "idea", "reminder", "bookmark", "meeting", "habit", "file", "network", "company", "event", "community"] + customTypeSlugs,
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
            )
        ],

        // MARK: Search / fetch
        [
            "name": Name.search_items.rawValue,
            "description": "Search and/or list items with optional text match, date range, and sort order. Returns id, type, title, a short snippet, and the 'date' each result was ranked by. Use get_item for full content, or `read_file` for the full text of `file` items. You can call this with NO query to simply list items by date — e.g. 'most recent emails', 'reminders due next', 'notes from last week', 'files I imported', 'X posts about the launch', 'DMs from Sam'.",
            "input_schema": objectSchema(
                properties: [
                    "query": stringProp("Optional free-text query (case-insensitive substring match on title/content; also matches file names, tags, OCR'd / extracted text, X post text, follower bio/handle, DM body). Omit to list everything matching the other filters."),
                    "types": [
                        "type": "array",
                        "description": "Limit to these types. Default: all of (todo, note, idea, reminder, bookmark, meeting, email, connection, network, company, event, community, file, x_post, x_follower, x_dm"
                            + (customTypeSlugs.isEmpty ? "" : ", plus the user's custom tabs: " + customTypeSlugs.joined(separator: ", "))
                            + "). `connection` is the raw LinkedIn CSV import; `network` is the curated Network Hub (people & orgs with structured LinkedIn profiles — summary, experience, education, skills, languages, certifications — all of it searchable). `company`/`event`/`community` are the location CRM: companies (with is-customer, $ commitment, website, and linked Network Hub people), events you're hosting/attending/considering (type, city, dates, budget), and communities/incubators — each has a city, notes and tags, all searchable. `file` covers user-imported PDFs / CSVs / images / text files. `x_post`/`x_follower`/`x_dm` cover synced X (Twitter) data.",
                        "items": [
                            "type": "string",
                            "enum": ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "network", "company", "event", "community", "habit", "file", "x_post", "x_follower", "x_dm"] + customTypeSlugs
                        ]
                    ],
                    "sort": enumProp(
                        ["recent", "oldest", "due_soonest", "title"],
                        "Sort order. 'recent' (default) = newest first by the item's primary date (emails=receivedDate, meetings=meetingDate, reminders=reminderDate, else updatedAt). 'oldest' = opposite. 'due_soonest' = ascending for todos/reminders with a date, others placed after. 'title' = alphabetical."
                    ),
                    "since": stringProp("ISO8601 datetime lower bound (inclusive) on the primary date, e.g. 2026-04-10T00:00:00Z. Filters out anything older."),
                    "until": stringProp("ISO8601 datetime upper bound (inclusive) on the primary date. Filters out anything newer."),
                    "include_completed": [
                        "type": "boolean",
                        "description": "When false, hides completed todos and reminders. Default true."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Max results (default 20, max 100).",
                        "minimum": 1,
                        "maximum": 100
                    ]
                ],
                required: []
            )
        ],
        [
            "name": Name.grep_data.rawValue,
            "description": "Regex-search ONE data-workspace snapshot table (one record per line) and get back only the matching lines (CSV header included so you can map columns). Case-insensitive; tables are rebuilt fresh from live data on every call. Use for bulk / multi-entity / relational / analytical questions — one call with an alternation pattern (e.g. file=\"connections.csv\", pattern=\"molten|wing|revo\") replaces a whole chain of search_items calls. Tables: connections.csv, network_hub.csv, companies.csv, events.csv, communities.csv, todos.csv, reminders.csv, habits.csv, bookmarks.csv, files.csv, x_followers.csv, emails.jsonl, meetings.jsonl, notes.jsonl, ideas.jsonl, calendar_events.jsonl, x_posts.jsonl, x_dms.jsonl"
                + (customTypeSlugs.isEmpty ? "." : ", plus one per custom tab: " + customTypeSlugs.map { "custom_\($0).csv" }.joined(separator: ", ") + "."),
            "input_schema": objectSchema(
                properties: [
                    "file": stringProp("Table filename, e.g. \"connections.csv\" or \"emails.jsonl\"."),
                    "pattern": stringProp("Regular expression, matched case-insensitively against each record line."),
                    "max_results": [
                        "type": "integer",
                        "description": "Max matching lines to return (default 50, max 200).",
                        "minimum": 1,
                        "maximum": 200
                    ]
                ],
                required: ["file", "pattern"]
            )
        ],
        [
            "name": Name.get_item.rawValue,
            "description": "Fetch full details of a single item by id and type. For files, returns metadata plus a short text preview — use `read_file` for the full extracted content.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the item."),
                    "type": enumProp(
                        ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "network", "company", "event", "community", "habit", "file", "x_post", "x_follower", "x_dm"] + customTypeSlugs,
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
            )
        ],
        [
            "name": Name.attach_item_preview.rawValue,
            "description": "Attach a large standalone clickable preview card for one item below your response text. For referencing items WITHIN your prose, prefer inline markdown links — `[Title](otto://<type>/<id>)` — which render as small clickable chips; reserve this tool for the 1-3 headline items of your answer. Never both card and inline-link the same item.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the item (from search_items or get_item)."),
                    "type": enumProp(
                        ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "network", "company", "event", "community", "habit", "file", "x_post", "x_follower", "x_dm"],
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
            )
        ],
        [
            "name": Name.visualize.rawValue,
            "description": "Render a native inline visualization card (table, bar chart, line chart, pie chart, or stat tiles) in the chat transcript. ALWAYS use this instead of markdown pipe tables or ASCII charts — pipe tables do NOT render in this chat and show as raw text. type='table': set `columns` + `rows` (detailed listings). type='bar': set `series` (categorical comparisons; multiple series render grouped). type='line': set `series` (trends over ordered labels — put labels in chronological order). type='pie': set `series` with exactly one entry whose points are the slices (composition/breakdown). type='stats': set `stats` (2-8 headline metrics as big number tiles). Table cells and stat `detail` lines may embed inline item links — `[Title](otto://<type>/<id>)`, same syntax as in prose — which render as clickable chips opening the item's detail popup; when a table row is about a specific existing item (a person, company, meeting…), write that cell as an item link with a real id from search_items/get_item (never invent ids). Chart point labels can't be clickable — item links there display as the bare title. Call once per visual — multiple calls per answer are fine. Keep surrounding prose to the takeaways; the card carries the data.",
            "input_schema": objectSchema(
                properties: [
                    "type": enumProp(["table", "bar", "line", "pie", "stats"], "Which visualization to render."),
                    "title": stringProp("Short title shown in the card header."),
                    "subtitle": stringProp("Optional one-line context under the title."),
                    "columns": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Table column headers (type='table')."
                    ] as [String: Any],
                    "rows": [
                        "type": "array",
                        "items": ["type": "array", "items": ["type": ["string", "number"]]],
                        "description": "Table rows aligned with `columns`; cells may be strings or numbers (type='table'). A cell naming a specific existing item should be an inline item link: `[Title](otto://<type>/<id>)`."
                    ] as [String: Any],
                    "series": [
                        "type": "array",
                        "description": "Chart series (type='bar'|'line'|'pie'). Each series: {name, points:[{label, value}]}. Values must be numbers.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Series name, shown in the legend."],
                                "points": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "label": ["type": "string"],
                                            "value": ["type": "number"]
                                        ],
                                        "required": ["label", "value"]
                                    ]
                                ] as [String: Any]
                            ],
                            "required": ["points"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "stats": [
                        "type": "array",
                        "description": "Headline metric tiles (type='stats'). Each: {label, value, detail?}.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string"],
                                "value": ["type": ["string", "number"], "description": "The headline value, pre-formatted (e.g. \"2,971\" or \"36%\")."],
                                "detail": ["type": "string", "description": "Optional small line under the value, e.g. a delta or caveat. May embed an inline item link `[Title](otto://<type>/<id>)`."]
                            ],
                            "required": ["label", "value"]
                        ] as [String: Any]
                    ] as [String: Any]
                ],
                required: ["type"]
            )
        ],
        [
            "name": Name.open_url.rawValue,
            "description": "Open a web URL in the user's default browser. Use this when the user's request would be answered by pointing them at a specific page — e.g. 'chill background music' → open a YouTube playlist search, 'news on X' → open a relevant article, 'book a flight' → open the airline's booking page. Only http:// or https:// URLs are allowed. Construct a sensible search URL (e.g. https://www.youtube.com/results?search_query=... or https://www.google.com/search?q=...) when you don't have a known canonical link. Prefer search-result URLs over specific video/page IDs you're unsure of. Keep `reason` short — it's shown to the user as confirmation.",
            "input_schema": objectSchema(
                properties: [
                    "url": stringProp("Full https:// URL to open in the default browser."),
                    "reason": stringProp("Short user-facing phrase describing what's being opened, e.g. 'YouTube search for lo-fi music'.")
                ],
                required: ["url"]
            )
        ],

        // MARK: Habits
        [
            "name": Name.create_habit.rawValue,
            "description": "Create a habit the user wants to track. Infer sensible defaults from how they describe it: 'drink 2.5L water daily' → kind=quantity, unit='mL', daily_target=2500, frequency=daily; 'read 30 min every day' → kind=duration, unit='min', daily_target=30; 'workout 3x a week' → kind=binary, frequency=weekly, weekly_count=3; 'no porn' → kind=binary, frequency=daily. Pick a relevant SF Symbol (drop.fill, book, figure.run, brain.head.profile, leaf, fork.knife, bed.double, sparkles, etc.) for `icon`.",
            "input_schema": objectSchema(
                properties: [
                    "title": stringProp("Short name of the habit, e.g. 'Water', 'Reading', 'No Porn'."),
                    "notes": stringProp("Optional longer description or motivation."),
                    "kind": enumProp(
                        ["binary", "quantity", "duration", "count"],
                        "binary = simple done/not done. quantity = numeric amount with a unit (e.g. mL of water, g of protein). duration = time-based (e.g. minutes of reading). count = integer reps (e.g. pushups, glasses of water). Default binary."
                    ),
                    "unit": stringProp("Unit string for quantity/duration/count, e.g. 'mL', 'min', 'g', 'pages', 'reps'. Omit for binary."),
                    "daily_target": ["type": "number", "description": "Per-day target value. For binary use 1 (default). For 2.5L water use 2500 with unit='mL'."],
                    "frequency": enumProp(
                        ["daily", "weekdays", "weekly"],
                        "daily = every day. weekdays = only specific days (provide `weekdays`). weekly = a target number of times per week (provide `weekly_count`)."
                    ),
                    "weekdays": [
                        "type": "array",
                        "description": "Required when frequency=weekdays. Days of the week the habit is required.",
                        "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]
                    ],
                    "weekly_count": ["type": "integer", "description": "Required when frequency=weekly. How many times per week.", "minimum": 1, "maximum": 7],
                    "category": enumProp(
                        ["health", "fitness", "learning", "mindfulness", "personalCare", "nutrition", "productivity", "custom"],
                        "Bucket for grouping. Default 'custom'."
                    ),
                    "icon": stringProp("SF Symbol name, e.g. 'drop.fill', 'book', 'figure.run'. Defaults to 'checkmark.circle'."),
                    "color": enumProp(
                        ["cyan", "green", "amber", "red", "aiAccent", "cyanDim", "hobby"],
                        "Tint color tag. Defaults to 'cyan'."
                    )
                ],
                required: ["title"]
            )
        ],
        [
            "name": Name.log_habit_entry.rawValue,
            "description": "Log a quantitative entry for a habit. Use when the user reports doing some amount of a habit — 'I drank 500ml', 'read for 25 minutes', 'did 30 pushups', 'ate 80g of protein'. Resolve `habit` by name (e.g. 'water', 'reading') if you don't have its UUID. For binary habits where the user just says they did it, prefer `complete_habit`. Date defaults to now.",
            "input_schema": objectSchema(
                properties: [
                    "habit": stringProp("UUID of the habit, OR a fuzzy name to look up (case-insensitive contains match)."),
                    "value": ["type": "number", "description": "Amount logged in the habit's unit. Default 1 (good for count/binary). For 'I drank 500ml' use 500."],
                    "date": stringProp("ISO8601 timestamp; defaults to now. Use to back-fill earlier in the day or yesterday."),
                    "note": stringProp("Optional short note attached to the entry, e.g. 'with lemon'.")
                ],
                required: ["habit"]
            )
        ],
        [
            "name": Name.complete_habit.rawValue,
            "description": "Mark a habit as fully completed for the day in one call. Use when the user says they finished something with no specific quantity — 'done with my workout', 'meditated today', 'made my bed'. For binary habits this logs a single completion; for quantity/duration habits it logs whatever value is needed to hit the daily target.",
            "input_schema": objectSchema(
                properties: [
                    "habit": stringProp("UUID of the habit, OR a fuzzy name to look up.")
                ],
                required: ["habit"]
            )
        ],
        [
            "name": Name.update_habit.rawValue,
            "description": "Update a habit's definition — rename, change target / unit / frequency / icon, or archive it. Only include fields you want to change. For logging progress use `log_habit_entry` / `complete_habit` instead.",
            "input_schema": objectSchema(
                properties: [
                    "habit": stringProp("UUID of the habit, OR a fuzzy name to look up (case-insensitive contains match)."),
                    "title": stringProp(""),
                    "notes": stringProp(""),
                    "kind": enumProp(["binary", "quantity", "duration", "count"], ""),
                    "unit": stringProp("Unit string, e.g. 'mL', 'min'. Empty string clears it."),
                    "daily_target": ["type": "number", "description": "Per-day target value."],
                    "frequency": enumProp(
                        ["daily", "weekdays", "weekly"],
                        "Provide `weekdays` or `weekly_count` alongside when relevant."
                    ),
                    "weekdays": [
                        "type": "array",
                        "description": "Required when frequency=weekdays.",
                        "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]
                    ],
                    "weekly_count": ["type": "integer", "description": "Required when frequency=weekly.", "minimum": 1, "maximum": 7],
                    "category": enumProp(
                        ["health", "fitness", "learning", "mindfulness", "personalCare", "nutrition", "productivity", "custom"],
                        ""
                    ),
                    "icon": stringProp("SF Symbol name."),
                    "color": enumProp(["cyan", "green", "amber", "red", "aiAccent", "cyanDim", "hobby"], ""),
                    "archived": ["type": "boolean", "description": "Archive (true) or restore (false) the habit."]
                ],
                required: ["habit"]
            )
        ],
        [
            "name": Name.list_habits.rawValue,
            "description": "Return the user's habits with today's progress, target, current streak, and 7-day completion rate. Use when the user asks 'how am I doing today?', 'am I on track?', 'what habits did I miss?', or before any operation where you need to discover the habit ids.",
            "input_schema": objectSchema(
                properties: [
                    "include_archived": ["type": "boolean", "description": "Include habits the user has archived. Default false."]
                ],
                required: []
            )
        ],
        [
            "name": Name.read_file.rawValue,
            "description": "Read the contents of a file the user imported into Otto (PDF, CSV, image, plain-text formats like txt/md/json, etc.). Returns the extracted text plus a local path where the file binary is staged in the current working directory — so you can ALSO use the built-in `Read` tool with that path if you need to see the file directly (especially useful for images, which `Read` handles natively, or for raw PDFs). Always call `search_items` (type=`file`) first to find the file id you want.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the file (returned by `search_items` with type=file or by `get_item`)."),
                    "max_chars": ["type": "integer", "description": "Cap the returned extracted text to this many characters. Default 20000, max 200000. Use to keep responses bounded for very large PDFs."]
                ],
                required: ["id"]
            )
        ],

        [
            "name": Name.create_file.rawValue,
            "description": "Create a downloadable file and hand it to the user in chat. The file is saved into Otto's Files tab and a clickable download card is attached to your reply AUTOMATICALLY — do NOT also call attach_item_preview for it. Format follows the filename extension: .csv/.txt/.md/.json/.yaml/.html/.xml/.log take raw text in `content`; .xlsx takes `sheets` (one tab per section: [{name, rows}]) or `rows` for a single table — first row of each sheet = headers (styled, frozen, and filterable automatically; numbers stay numeric); .pdf takes markdown-ish text in `content` (# headings, - bullets, **bold**, | table rows render styled). Use whenever the user asks for a file, export, spreadsheet, report, or anything to download — don't paste the file's full contents into your prose afterwards.",
            "input_schema": objectSchema(
                properties: [
                    "filename": stringProp("File name including extension, e.g. 'q3-report.xlsx', 'contacts.csv', 'summary.pdf'. No path separators."),
                    "content": stringProp("The file's text content (csv/txt/md/json/yaml/html/xml/log), or the markdown body to render (pdf). Ignored for xlsx."),
                    "sheets": [
                        "type": "array",
                        "description": "For .xlsx — PREFERRED: one worksheet tab per logical section, e.g. [{\"name\": \"Summary\", \"rows\": [[…]]}, {\"name\": \"By City\", \"rows\": [[…]]}]. Each sheet's first row is its header row (rendered bold, frozen, filterable); don't cram unrelated sections into one sheet.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Worksheet tab name, e.g. 'Summary', 'By City'."],
                                "rows": ["type": "array", "description": "Worksheet rows, each an array of cell values (string, number, boolean, or null). First row = headers.", "items": ["type": "array"]]
                            ],
                            "required": ["name", "rows"]
                        ]
                    ],
                    "rows": [
                        "type": "array",
                        "description": "For .xlsx, single-sheet shorthand: worksheet rows, each an array of cell values (string, number, boolean, or null). First row is the header row. Prefer `sheets` when the data has more than one section.",
                        "items": ["type": "array"]
                    ],
                    "sheet_name": stringProp("For .xlsx with `rows`: the worksheet tab name. Defaults to 'Sheet1'."),
                    "notes": stringProp("Optional one-line description saved on the file (shown in the Files tab).")
                ],
                required: ["filename"]
            )
        ],

        // MARK: GenMedia (fal.ai)
        //
        // Available only when the genmedia CLI is installed AND the user has
        // set a fal API key. AgentService.buildSystemPrompt gates the prose
        // hint on those preconditions; if the agent tries to call these
        // tools without them, the executor returns a friendly error pointing
        // at Integrations → GenMedia.
        [
            "name": Name.genmedia_search_models.rawValue,
            "description": "Search fal.ai's model catalog through the genmedia CLI. Use this first when the user asks to generate, draw, render, animate, or produce any media — search for an appropriate model, then inspect its schema with `genmedia_get_model_schema`, then call `genmedia_run`. Returns up to `limit` matches as id/name/category triples.",
            "input_schema": objectSchema(
                properties: [
                    "query": stringProp("Free-text query, e.g. 'flux', 'image-to-video', 'speech', 'logo'."),
                    "category": stringProp("Optional category filter. Common values: image, video, audio, text-to-speech, music, vision."),
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50).", "minimum": 1, "maximum": 50]
                ],
                required: []
            )
        ],
        [
            "name": Name.genmedia_get_model_schema.rawValue,
            "description": "Inspect a fal.ai model's input fields via `genmedia schema`. Returns the JSON schema for the model's parameters so you know exactly what to pass to `genmedia_run` (required fields, types, enums, defaults). Always call this before `genmedia_run` for any unfamiliar model.",
            "input_schema": objectSchema(
                properties: [
                    "model_id": stringProp("Full fal model id, e.g. 'fal-ai/flux/dev' or 'fal-ai/veo3.1' (from `genmedia_search_models`).")
                ],
                required: ["model_id"]
            )
        ],
        [
            "name": Name.genmedia_run.rawValue,
            "description": "Generate media synchronously via `genmedia run`. Saves outputs into Otto's Files tab and returns the new file ids — call `attach_item_preview` with type=`file` afterwards to give the user click-through previews in your reply. Generation can take 5-120 seconds depending on the model (videos especially); if it times out, fall back to a faster model. The user's fal account is billed directly.",
            "input_schema": objectSchema(
                properties: [
                    "model_id": stringProp("Full fal model id, e.g. 'fal-ai/flux/dev'."),
                    "inputs": [
                        "type": "object",
                        "description": "Model-specific inputs. Match the field names returned by `genmedia_get_model_schema`. Typical examples: prompt, image_url, num_images, image_size, seed, duration. Nested objects/arrays are passed through as JSON."
                    ],
                    "prompt_summary": stringProp("Short human-readable summary of what's being generated (used as the file's notes field). Optional but recommended.")
                ],
                required: ["model_id", "inputs"]
            )
        ],
        [
            "name": Name.genmedia_upload_file.rawValue,
            "description": "Upload one of the user's existing Otto files to fal's CDN via `genmedia upload`. Returns a CDN URL you can pass into another model's inputs (e.g. as `image_url` for an image-to-image flow). Use when the user references an image/video they already have in Files.",
            "input_schema": objectSchema(
                properties: [
                    "file_id": stringProp("UUID of an Otto File (from `search_items` with type=file).")
                ],
                required: ["file_id"]
            )
        ]
        ]
    }

    // MARK: - Custom-tab generated tools

    enum CustomTabToolAction {
        case create, update
    }

    /// If `raw` (bare or MCP-prefixed) names a generated custom-tab tool,
    /// return the action + owning tab. The executor and tool-label code route
    /// through this so name matching can't drift from the generation above.
    static func customTabTool(named raw: String, tabs: [CustomTabDefinition]) -> (action: CustomTabToolAction, tab: CustomTabDefinition)? {
        let name = canonicalToolName(raw)
        for tab in tabs {
            if name == "create_\(tab.slug)" { return (.create, tab) }
            if name == "update_\(tab.slug)" { return (.update, tab) }
        }
        return nil
    }

    private static func createTool(for tab: CustomTabDefinition) -> [String: Any] {
        let keys = tab.fieldKeys()
        var properties: [String: Any] = [:]
        for (key, field) in keys {
            properties[key] = fieldProp(field, forUpdate: false)
        }
        // The first (title) column is required when it's a text field —
        // matches the UI, which renders it as the record's display title.
        let required: [String] = {
            guard let primary = keys.first, primary.field.kind == .text else { return [] }
            return [primary.key]
        }()
        let columns = keys.map { "\($0.key) (\(kindDoc($0.field)))" }.joined(separator: ", ")
        return [
            "name": "create_\(tab.slug)",
            "description": "Add a row to the user's custom \"\(tab.name)\" tab. Columns: \(columns).",
            "input_schema": objectSchema(properties: properties, required: required)
        ]
    }

    private static func updateTool(for tab: CustomTabDefinition) -> [String: Any] {
        var properties: [String: Any] = [
            "id": stringProp("UUID of the record (from search_items with type=\(tab.slug)).")
        ]
        for (key, field) in tab.fieldKeys() {
            properties[key] = fieldProp(field, forUpdate: true)
        }
        return [
            "name": "update_\(tab.slug)",
            "description": "Update fields on a row in the user's custom \"\(tab.name)\" tab. Only include fields you want to change. Delete rows via delete_item(type=\"\(tab.slug)\").",
            "input_schema": objectSchema(properties: properties, required: ["id"])
        ]
    }

    /// JSON-schema property for one custom field. Select kinds surface their
    /// option labels as enums so the model can't invent values.
    private static func fieldProp(_ field: CustomFieldDefinition, forUpdate: Bool) -> [String: Any] {
        switch field.kind {
        case .text, .longText:
            return forUpdate ? stringProp("Empty string clears it.") : ["type": "string"]
        case .url:
            return stringProp(forUpdate ? "URL. Empty string clears it." : "URL.")
        case .number:
            return ["type": "number"]
        case .date:
            return stringProp("ISO8601 date or datetime, e.g. 2026-07-08 or 2026-07-08T17:00:00Z."
                + (forUpdate ? " Empty string clears it." : ""))
        case .checkbox:
            return ["type": "boolean"]
        case .singleSelect:
            let labels = field.options.map(\.label)
            return enumProp(
                forUpdate ? labels + [""] : labels,
                forUpdate ? "Empty string clears it." : ""
            )
        case .multiSelect:
            var out: [String: Any] = [
                "type": "array",
                "items": ["type": "string", "enum": field.options.map(\.label)]
            ]
            if forUpdate { out["description"] = "Replaces the full list. Empty array clears it." }
            return out
        }
    }

    /// Compact per-column type note for the create tool's description.
    private static func kindDoc(_ field: CustomFieldDefinition) -> String {
        switch field.kind {
        case .text: return "text"
        case .longText: return "long text"
        case .number: return "number"
        case .date: return "date"
        case .checkbox: return "checkbox"
        case .url: return "url"
        case .singleSelect: return "one of: " + field.options.map(\.label).joined(separator: "|")
        case .multiSelect: return "any of: " + field.options.map(\.label).joined(separator: "|")
        }
    }

    // MARK: - Schema helpers

    private static func objectSchema(properties: [String: Any], required: [String] = []) -> [String: Any] {
        var out: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty { out["required"] = required }
        return out
    }

    private static func stringProp(_ description: String) -> [String: Any] {
        description.isEmpty ? ["type": "string"] : ["type": "string", "description": description]
    }

    private static func enumProp(_ values: [String], _ description: String) -> [String: Any] {
        var out: [String: Any] = ["type": "string", "enum": values]
        if !description.isEmpty { out["description"] = description }
        return out
    }

    private static func arrayOfStrings(_ description: String) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": ["type": "string"]
        ]
    }
}
