import Foundation

/// Exports every Otto tab as a grep-able snapshot file — CSV for tabular tabs
/// (connections, network hub, companies…), JSONL for text-heavy ones (emails,
/// meetings, notes…) — into the agent CLI's per-turn working directory.
///
/// Why: bulk / relational / analytical questions ("which funds am I connected
/// to?") used to fan out into 30–40 `search_items` MCP round trips, each
/// dumping a 50-item JSON blob into the model's context. With the tabs on
/// disk, the same question is one `grep -iE "a|b|c" connections.csv` that
/// returns only the matching lines. `search_items` stays for freshness and
/// single lookups; `get_item` stays for full detail (email bodies etc.).
///
/// Flow per turn (Claude/Codex CLI backends only — Hermes is a local sibling
/// process, but each backend has its own working dir, so Hermes reaches the
/// same tables through the `grep_data` MCP tool instead of these files):
///   1. `AgentService.buildSystemPrompt` embeds `promptSection(from:)` — the
///      file list with row counts + columns, so the agent knows what exists.
///   2. `ClaudeCLIService` / `CodexCLIService` call `snapshot(from:)` on the
///      main actor, then `write(_:into:)` into the conversation's session dir
///      before spawn — skipped entirely when `isCurrent` says no store write
///      happened since the last export (see the revision marker below).
///   3. Session dirs (0700) live under $TMPDIR and are reclaimed by the OS.
///
/// Records are one-per-line (newlines inside fields are flattened) so `grep`
/// always returns whole records. Long text fields are clipped — the row always
/// carries the item's `id` so the agent can chain into `get_item` /
/// `attach_item_preview` / `read_file` for the full record.
enum AgentWorkspaceExporter {

    // MARK: - Snapshot

    /// Value-type copy of every exportable tab, captured on the main actor so
    /// serialization + file IO can happen off-main on the CLI service actor.
    struct Snapshot {
        var todos: [Todo] = []
        var notes: [Note] = []
        var ideas: [Idea] = []
        var reminders: [Reminder] = []
        var bookmarks: [Bookmark] = []
        var meetings: [Meeting] = []
        var emails: [Email] = []
        var connections: [Connection] = []
        var networkEntries: [NetworkEntry] = []
        var companies: [Company] = []
        var events: [Event] = []
        var communities: [Community] = []
        var files: [FileItem] = []
        var habits: [Habit] = []
        var calendarEvents: [CalendarEvent] = []
        var xFollowers: [XFollower] = []
        var xPosts: [XPost] = []
        var xDirectMessages: [XDirectMessage] = []
        var customTabs: [CustomTabDefinition] = []
        var customRecords: [CustomRecord] = []
        var tagNames: [UUID: String] = [:]
        var generatedAt: Date = Date()
    }

    /// Reads the AppState arrays. Called on the main actor by the CLI
    /// services; `buildSystemPrompt` calls it from its existing nonisolated
    /// context (it already reads these arrays directly — same pattern).
    static func snapshot(from appState: AppState) -> Snapshot {
        var s = Snapshot()
        s.todos = appState.todos
        s.notes = appState.notes
        s.ideas = appState.ideas
        s.reminders = appState.reminders
        s.bookmarks = appState.bookmarks
        s.meetings = appState.meetings
        s.emails = appState.emails
        s.connections = appState.connections
        s.networkEntries = appState.networkEntries
        s.companies = appState.companies
        s.events = appState.events
        s.communities = appState.communities
        s.files = appState.files
        s.habits = appState.habits.filter { !$0.isArchived }
        s.calendarEvents = appState.calendarEvents
        s.xFollowers = appState.xFollowers
        s.xPosts = appState.xPosts
        s.xDirectMessages = appState.xDirectMessages
        s.customTabs = appState.customTabs
        s.customRecords = appState.customRecords
        s.tagNames = Dictionary(appState.domainTags.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        s.generatedAt = Date()
        return s
    }

    // MARK: - Write

    /// Marker file recording which `PersistenceService.revision` the files in
    /// a workspace dir were exported at — lets follow-up turns in a stable
    /// per-session dir skip the whole multi-MB re-serialize when no store
    /// write happened in between.
    private static let revisionMarker = ".otto_workspace_revision"

    /// True when `dir` already holds an export stamped with `revision`.
    static func isCurrent(_ dir: URL, revision: Int) -> Bool {
        let markerURL = dir.appendingPathComponent(revisionMarker)
        guard let stamp = try? String(contentsOf: markerURL, encoding: .utf8),
              stamp.trimmingCharacters(in: .whitespacesAndNewlines) == String(revision),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("_manifest.md").path)
        else { return false }
        return true
    }

    /// Serialize the snapshot into `dir` (the CLI's cwd for this turn) plus a
    /// `_manifest.md` describing the files. Best-effort: a failed file is
    /// logged and skipped — the agent falls back to search_items. Pass
    /// `revision` (from `PersistenceService.revision` at snapshot time) to
    /// stamp the dir for `isCurrent` skip checks on later turns.
    static func write(_ snap: Snapshot, into dir: URL, revision: Int? = nil) {
        let specs = fileSpecs(from: snap, includeContent: true)
        guard !specs.isEmpty else { return }

        var manifest: [String] = []
        manifest.append("# Otto data workspace")
        manifest.append("Generated \(iso(snap.generatedAt)). One record per line; long fields clipped.")
        manifest.append("Full record: `get_item(type, id)` — file text: `read_file(id)`. Data created/updated during this conversation is NOT in these files; use search_items for freshness.")
        manifest.append("")

        for spec in specs {
            let url = dir.appendingPathComponent(spec.filename)
            do {
                try spec.content.write(to: url, atomically: true, encoding: .utf8)
                manifest.append("- `\(spec.filename)` — \(spec.count) rows: \(spec.doc)")
            } catch {
                NSLog("[AgentWorkspace] failed to write %@: %@", spec.filename, error.localizedDescription)
            }
        }

        let manifestURL = dir.appendingPathComponent("_manifest.md")
        try? manifest.joined(separator: "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        if let revision {
            let markerURL = dir.appendingPathComponent(revisionMarker)
            try? String(revision).write(to: markerURL, atomically: true, encoding: .utf8)
        }
        // tmpDir already lives under the user-private $TMPDIR; tighten anyway.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    // MARK: - System prompt section

    /// How the active backend reaches the workspace tables.
    enum Access {
        /// CLI backends (Claude Code / Codex): real files exported into the
        /// agent subprocess's cwd — searched with its own Read/Grep tools.
        case localFiles
        /// MCP-only backends (Hermes): runs locally but in its own working
        /// dir without these files — the same tables are served through the
        /// `grep_data` MCP tool, generated fresh on every call.
        case mcpGrep
    }

    /// The "## Data workspace" block for `buildSystemPrompt` — file list with
    /// row counts + columns so the agent reaches for grep before search_items.
    /// nil when every tab is empty (fresh install).
    static func promptSection(from appState: AppState, access: Access) -> String? {
        let specs = fileSpecs(from: snapshot(from: appState), includeContent: false)
        guard !specs.isEmpty else { return nil }

        var out: [String] = []
        switch access {
        case .localFiles:
            out.append("## Data workspace (files in your working directory)")
            out.append("Your cwd contains a fresh snapshot of the user's Otto data, one record per line. For bulk, multi-entity, relational, or analytical questions (\"which funds…\", \"count by city\", \"cross-reference emails and connections\") — Grep/Read these files FIRST. One `grep -iE \"acme|globex\" connections.csv` beats a chain of search_items calls and returns only the matching lines.")
        case .mcpGrep:
            out.append("## Data workspace (grep_data tool)")
            out.append("The `grep_data` tool regex-searches snapshot tables of the user's Otto data (one record per line) and returns ONLY the matching lines. For bulk, multi-entity, relational, or analytical questions (\"which funds…\", \"who do I know in <city>…\", \"cross-reference emails and connections\") call grep_data FIRST — one call with an alternation pattern, e.g. grep_data(file: \"connections.csv\", pattern: \"molten|wing|revo\"), replaces a whole chain of search_items calls. NEVER call search_items once per entity.")
        }
        for spec in specs {
            out.append("- \(spec.filename) — \(spec.count) rows: \(spec.doc)")
        }
        switch access {
        case .localFiles:
            out.append("""
            Workspace rules:
            - Every row carries the item's `id` — chain into `get_item` for the full record (email bodies, meeting content; file text via `read_file`) and `attach_item_preview` for clickable cards.
            - The snapshot is taken when your turn starts. Anything you create/update/delete mid-turn shows up only via search_items/get_item — not in these files.
            - Prefer these files over repeated search_items calls for anything bulk or analytical; keep search_items for single targeted lookups or post-mutation freshness. This overrides the earlier guidance about calling search_items for relational / cross-source questions — Grep the workspace instead, then synthesize.
            """)
        case .mcpGrep:
            out.append("""
            Workspace rules:
            - Every row carries the item's `id` — chain into `get_item` for the full record (email bodies, meeting content; file text via `read_file`) and `attach_item_preview` for clickable cards.
            - Tables are generated fresh on every grep_data call, so they always reflect current data — including items you just created or updated this turn.
            - Case-insensitive regex per line; pattern \".\" lists rows (rows are pre-sorted: people alphabetical, time-series newest first; cap with max_results).
            - Prefer grep_data over repeated search_items calls for anything bulk or analytical. This overrides the earlier guidance about calling search_items for relational / cross-source questions — grep the workspace instead, then synthesize.
            """)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - MCP grep (remote backends)

    /// Regex-search one workspace table and return the matching lines —
    /// `grep_data`'s implementation. Builds only the requested table, fresh
    /// from AppState, so results always reflect current data.
    static func grep(file: String, pattern: String, maxResults: Int, appState: AppState) -> (text: String, matchCount: Int, isError: Bool) {
        let snap = snapshot(from: appState)
        let specs = fileSpecs(from: snap, includeContent: true, only: file)
        guard let spec = specs.first(where: { $0.filename == file }) else {
            let available = specs.map(\.filename).joined(separator: ", ")
            let hint = available.isEmpty ? "(none — every tab is empty)" : available
            return ("Unknown or empty table \"\(file)\". Available: \(hint)", 0, true)
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            return ("Invalid regex /\(pattern)/: \(error.localizedDescription)", 0, true)
        }

        var lines = spec.content.components(separatedBy: "\n")
        // Keep the CSV header out of matching but always return it so the
        // model can map columns.
        let header: String? = file.hasSuffix(".csv") && !lines.isEmpty ? lines.removeFirst() : nil

        var matched: [String] = []
        var total = 0
        for line in lines where !line.isEmpty {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                total += 1
                if matched.count < maxResults { matched.append(line) }
            }
        }

        var out: [String] = []
        var headline = "# \(file): \(total) of \(spec.count) records match /\(pattern)/i"
        if total > matched.count { headline += " (showing first \(matched.count) — raise max_results or narrow the pattern)" }
        out.append(headline)
        if let header { out.append(header) }
        out.append(contentsOf: matched)
        if total == 0 { out.append("(no matches — try a broader pattern or another table)") }
        return (out.joined(separator: "\n"), total, false)
    }

    // MARK: - File specs

    private struct FileSpec {
        let filename: String
        let count: Int
        /// One-line schema shown in the manifest + system prompt.
        let doc: String
        /// Full file body; empty when built for the prompt (counts only).
        let content: String
    }

    /// Single source of truth for which files exist, their names, schemas and
    /// contents — the prompt (includeContent: false), the writer
    /// (includeContent: true) and grep_data (`only:` one table) can never
    /// drift apart.
    private static func fileSpecs(from snap: Snapshot, includeContent: Bool, only: String? = nil) -> [FileSpec] {
        var specs: [FileSpec] = []

        func add(_ filename: String, _ count: Int, _ doc: String, _ build: () -> String) {
            guard count > 0 else { return }
            let wantContent = includeContent && (only == nil || only == filename)
            specs.append(FileSpec(
                filename: filename,
                count: count,
                doc: doc,
                content: wantContent ? build() : ""
            ))
        }

        // ---- CSV: tabular tabs ----

        add("connections.csv", snap.connections.count,
            "id,name,headline,company,location,email,closeness,category,tags,connected_on,last_contacted,notes (LinkedIn connections)") {
            var rows = [csvRow(["id", "name", "headline", "company", "location", "email", "closeness", "category", "tags", "connected_on", "last_contacted", "notes"])]
            for c in snap.connections.sorted(by: { $0.fullName.lowercased() < $1.fullName.lowercased() }) {
                rows.append(csvRow([
                    c.id.uuidString, c.fullName, c.headline, c.company, c.location,
                    c.email ?? "", c.closeness.rawValue, c.category.rawValue,
                    c.tags.joined(separator: "|"),
                    c.connectionDate.map(day) ?? "",
                    c.lastContactedAt.map(day) ?? "",
                    clip(c.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("network_hub.csv", snap.networkEntries.count,
            "id,name,company,type,individual_type,title,industry,location,email,closeness,past_companies,skills,notes (curated people/orgs CRM)") {
            var rows = [csvRow(["id", "name", "company", "type", "individual_type", "title", "industry", "location", "email", "closeness", "past_companies", "skills", "notes"])]
            for n in snap.networkEntries.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                let pastCompanies = (n.profile?.experiences.map(\.company) ?? [])
                    .filter { !$0.isEmpty }
                var seen = Set<String>()
                let uniqPast = pastCompanies.filter { seen.insert($0.lowercased()).inserted }
                rows.append(csvRow([
                    n.id.uuidString, n.name, n.company, n.type.label, n.individualType.label,
                    n.title, n.industry, n.location, n.email, n.closeness.label,
                    uniqPast.prefix(8).joined(separator: "|"),
                    (n.profile?.skills ?? []).prefix(8).joined(separator: "|"),
                    clip(n.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("companies.csv", snap.companies.count,
            "id,name,type,location,is_customer,commitment_usd,website,tags,notes") {
            var rows = [csvRow(["id", "name", "type", "location", "is_customer", "commitment_usd", "website", "tags", "notes"])]
            for c in snap.companies.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                rows.append(csvRow([
                    c.id.uuidString, c.name, c.type.rawValue, c.location,
                    c.isCustomer ? "yes" : "no",
                    c.commitmentAmount.map { num($0) } ?? "",
                    c.website ?? "", c.tags.joined(separator: "|"), clip(c.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("events.csv", snap.events.count,
            "id,name,type,location,start,end,status,budget_usd,tags,notes") {
            var rows = [csvRow(["id", "name", "type", "location", "start", "end", "status", "budget_usd", "tags", "notes"])]
            for e in snap.events.sorted(by: { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }) {
                rows.append(csvRow([
                    e.id.uuidString, e.name, e.type.rawValue, e.location,
                    e.startDate.map(day) ?? "", e.endDate.map(day) ?? "",
                    e.status.rawValue,
                    e.budgetAmount.map { num($0) } ?? "",
                    e.tags.joined(separator: "|"), clip(e.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("communities.csv", snap.communities.count,
            "id,name,type,location,builder_perk,url,tags,notes") {
            var rows = [csvRow(["id", "name", "type", "location", "builder_perk", "url", "tags", "notes"])]
            for c in snap.communities.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                rows.append(csvRow([
                    c.id.uuidString, c.name, c.type.rawValue, c.location,
                    c.builderSupportPerk ? "yes" : "no",
                    c.url ?? "", c.tags.joined(separator: "|"), clip(c.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("todos.csv", snap.todos.count,
            "id,title,status,priority,due,project,tags,subtasks,description (status: open|done)") {
            let active = snap.todos.filter { !$0.isCompleted }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            let done = snap.todos.filter { $0.isCompleted }
                .sorted { $0.updatedAt > $1.updatedAt }
            var rows = [csvRow(["id", "title", "status", "priority", "due", "project", "tags", "subtasks", "description"])]
            for t in active + done {
                let subs = t.subTasks.isEmpty
                    ? ""
                    : "\(t.subTasks.filter(\.isCompleted).count)/\(t.subTasks.count): " + t.subTasks.map(\.title).joined(separator: "|")
                rows.append(csvRow([
                    t.id.uuidString, t.title, t.isCompleted ? "done" : "open",
                    t.priority.displayName,
                    t.dueDate.map(iso) ?? "",
                    t.todoistProjectName ?? "",
                    tagList(t.domainTagIds, snap),
                    clip(subs, 200),
                    clip(t.description, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("reminders.csv", snap.reminders.count,
            "id,title,when,status (status: pending|done)") {
            var rows = [csvRow(["id", "title", "when", "status"])]
            for r in snap.reminders.sorted(by: { $0.reminderDate > $1.reminderDate }) {
                rows.append(csvRow([
                    r.id.uuidString, r.title, iso(r.reminderDate),
                    r.isCompleted ? "done" : "pending"
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("habits.csv", snap.habits.count,
            "id,title,kind,target,unit,frequency,streak,today") {
            var rows = [csvRow(["id", "title", "kind", "target", "unit", "frequency", "streak", "today"])]
            for h in snap.habits.sorted(by: { $0.title.lowercased() < $1.title.lowercased() }) {
                let today: String
                if h.kind == .binary {
                    today = h.isMet(on: snap.generatedAt) ? "done" : "not done"
                } else {
                    today = "\(num(h.progress(on: snap.generatedAt)))/\(num(h.dailyTarget))\(h.unit.map { " \($0)" } ?? "")"
                }
                rows.append(csvRow([
                    h.id.uuidString, h.title, h.kind.rawValue,
                    num(h.dailyTarget), h.unit ?? "", h.frequency.displayName,
                    String(h.currentStreak(asOf: snap.generatedAt)), today
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("bookmarks.csv", snap.bookmarks.count,
            "id,title,url,site,read,tags,description") {
            var rows = [csvRow(["id", "title", "url", "site", "read", "tags", "description"])]
            for b in snap.bookmarks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                rows.append(csvRow([
                    b.id.uuidString, b.title, b.url, b.siteName ?? "",
                    b.isRead ? "yes" : "no",
                    tagList(b.domainTagIds, snap),
                    clip(b.description, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        add("files.csv", snap.files.count,
            "id,name,type,ext,size,tags,notes (imported files; full text via read_file)") {
            var rows = [csvRow(["id", "name", "type", "ext", "size", "tags", "notes"])]
            for f in snap.files.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                rows.append(csvRow([
                    f.id.uuidString, f.name, f.fileType.displayName, f.fileExtension,
                    ByteCountFormatter.string(fromByteCount: f.fileSize, countStyle: .file),
                    f.tags.joined(separator: "|"), clip(f.notes, 200)
                ]))
            }
            return rows.joined(separator: "\n")
        }

        // One table per custom-tab collection — columns from its schema.
        // Single-collection tabs keep the historical custom_<slug>.csv name;
        // multi-collection tabs get custom_<slug>__<collection>.csv each.
        for tab in snap.customTabs {
            for collection in tab.sortedCollections {
                let records = snap.customRecords.filter {
                    $0.tabId == tab.id && tab.collection(for: $0)?.id == collection.id
                }
                let keys = collection.fieldKeys()
                let columnNames = keys.map { $0.key }
                let filename = tab.collections.count == 1
                    ? "custom_\(tab.slug).csv"
                    : "custom_\(tab.slug)__\(collection.key).csv"
                let label = tab.collections.count == 1
                    ? "(user-defined \"\(tab.name)\" tab)"
                    : "(\"\(collection.name)\" collection of the \"\(tab.name)\" tab)"
                add(filename, records.count,
                    "id," + columnNames.joined(separator: ",") + ",updated " + label) {
                    var rows = [csvRow(["id"] + columnNames + ["updated"])]
                    for r in records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                        rows.append(csvRow(
                            [r.id.uuidString]
                            + keys.map { col in r.values[col.field.id].map { $0.displayString(for: col.field) } ?? "" }
                            + [iso(r.updatedAt)]
                        ))
                    }
                    return rows.joined(separator: "\n")
                }
            }
        }

        add("x_followers.csv", snap.xFollowers.count,
            "id,username,name,bio,followers,following,mutual (X/Twitter followers)") {
            var rows = [csvRow(["id", "username", "name", "bio", "followers", "following", "mutual"])]
            for f in snap.xFollowers.sorted(by: { $0.followersCount > $1.followersCount }) {
                rows.append(csvRow([
                    f.id.uuidString, f.username, f.displayName, clip(f.bio, 160),
                    String(f.followersCount), String(f.followingCount),
                    f.isMutual ? "yes" : "no"
                ]))
            }
            return rows.joined(separator: "\n")
        }

        // ---- JSONL: text-heavy tabs (newest first) ----

        add("emails.jsonl", snap.emails.count,
            "{date,from,from_name,to,subject,snippet,labels,read,id} — bodies via get_item") {
            snap.emails.sorted { $0.receivedDate > $1.receivedDate }.compactMap { e in
                jsonLine([
                    "date": iso(e.receivedDate),
                    "from": e.sender,
                    "from_name": e.senderName ?? "",
                    "to": e.recipients.prefix(5).joined(separator: ", "),
                    "subject": e.subject,
                    "snippet": clip(e.snippet, 200),
                    "labels": e.labels.joined(separator: "|"),
                    "read": e.isRead,
                    "id": e.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("meetings.jsonl", snap.meetings.count,
            "{date,title,organizer,participants,overview,action_items,id} — transcript via get_item") {
            snap.meetings.sorted { $0.meetingDate > $1.meetingDate }.compactMap { m in
                jsonLine([
                    "date": iso(m.meetingDate),
                    "title": m.title,
                    "organizer": m.organizer,
                    "participants": m.participants.joined(separator: ", "),
                    "overview": clip(m.overview, 400),
                    "action_items": clip(m.actionItems, 400),
                    "id": m.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("notes.jsonl", snap.notes.count,
            "{updated,title,category,tags,content,id} — full content via get_item") {
            snap.notes.sorted { $0.updatedAt > $1.updatedAt }.compactMap { n in
                jsonLine([
                    "updated": iso(n.updatedAt),
                    "title": n.title,
                    "category": n.primaryCategory.rawValue,
                    "tags": tagList(n.domainTagIds, snap),
                    "content": clip(n.content, 600),
                    "id": n.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("ideas.jsonl", snap.ideas.count,
            "{updated,title,status,tags,content,id}") {
            snap.ideas.sorted { $0.updatedAt > $1.updatedAt }.compactMap { i in
                jsonLine([
                    "updated": iso(i.updatedAt),
                    "title": i.title,
                    "status": i.status.rawValue,
                    "tags": tagList(i.domainTagIds, snap),
                    "content": clip(i.content, 600),
                    "id": i.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("calendar_events.jsonl", snap.calendarEvents.count,
            "{start,end,title,location,attendees,all_day,id} (Google Calendar sync)") {
            snap.calendarEvents.sorted { $0.startTime > $1.startTime }.compactMap { e in
                jsonLine([
                    "start": iso(e.startTime),
                    "end": iso(e.endTime),
                    "title": e.title,
                    "location": e.location ?? "",
                    "attendees": e.attendees.prefix(10).joined(separator: ", "),
                    "all_day": e.isAllDay,
                    "id": e.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("x_posts.jsonl", snap.xPosts.count,
            "{date,author,text,likes,reposts,id} (X/Twitter posts)") {
            snap.xPosts.sorted { $0.createdAt > $1.createdAt }.compactMap { p in
                jsonLine([
                    "date": iso(p.createdAt),
                    "author": "@\(p.authorUsername)",
                    "text": clip(p.text, 300),
                    "likes": p.likeCount,
                    "reposts": p.retweetCount,
                    "id": p.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        add("x_dms.jsonl", snap.xDirectMessages.count,
            "{date,from,text,conversation,id} (X/Twitter DMs)") {
            snap.xDirectMessages.sorted { $0.createdAt > $1.createdAt }.compactMap { d in
                jsonLine([
                    "date": iso(d.createdAt),
                    "from": "@\(d.senderUsername)",
                    "text": clip(d.text, 300),
                    "conversation": d.conversationId,
                    "id": d.id.uuidString
                ])
            }.joined(separator: "\n")
        }

        return specs
    }

    // MARK: - Formatting helpers

    /// Thread-safe ISO8601 in the user's local offset — matches the date
    /// guidance the system prompt gives the agent.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static func iso(_ d: Date) -> String {
        isoFormatter.string(from: d)
    }

    /// Date-only (yyyy-MM-dd), derived from the ISO string so no extra
    /// (thread-unsafe) DateFormatter is needed.
    private static func day(_ d: Date) -> String {
        String(iso(d).prefix(10))
    }

    /// Compact number — "2500" not "2500.0", "1.5" kept as-is.
    private static func num(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }

    private static func tagList(_ ids: [UUID], _ snap: Snapshot) -> String {
        ids.compactMap { snap.tagNames[$0] }.joined(separator: "|")
    }

    /// Flatten to a single line (grep returns whole records) and clip long
    /// fields — the id column is the escape hatch to the full record.
    private static func clip(_ s: String, _ max: Int) -> String {
        // Pre-truncate before collapsing so multi-MB fields (note bodies,
        // transcripts) aren't fully processed just to keep ~200 chars.
        let head = s.count > max * 8 ? String(s.prefix(max * 8)) : s
        let flat = head
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if flat.count <= max { return flat }
        return String(flat.prefix(max - 1)) + "…"
    }

    private static func csvField(_ raw: String) -> String {
        let s = clip(raw, 400)
        if s.contains(",") || s.contains("\"") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    /// One compact JSON object per line. Values must be JSON-encodable
    /// (String/Int/Bool). Sorted keys keep the files diff-stable.
    private static func jsonLine(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }
}
