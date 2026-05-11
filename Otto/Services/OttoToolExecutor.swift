import Foundation

/// Bridges Claude tool calls to AppState mutations. Lives on the MainActor because
/// every `add*` / `update*` / `delete*` method on AppState is @MainActor.
@MainActor
final class OttoToolExecutor {
    struct ToolResult {
        let content: String
        let isError: Bool
        /// Short human-readable line for the UI tool-chip (e.g. "Created todo: Buy milk").
        let summary: String
    }

    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Entry point

    func execute(name: String, input: [String: Any]) async -> ToolResult {
        guard let tool = OttoTools.Name(rawValue: name) else {
            return err("Unknown tool: \(name)", summary: "Unknown tool \(name)")
        }
        let result: ToolResult
        switch tool {
        case .create_todo:      result = await createTodo(input)
        case .create_note:      result = await createNote(input)
        case .create_idea:      result = await createIdea(input)
        case .create_reminder:  result = await createReminder(input)
        case .create_bookmark:  result = await createBookmark(input)
        case .update_todo:      result = await updateTodo(input)
        case .update_note:      result = await updateNote(input)
        case .update_idea:      result = await updateIdea(input)
        case .complete_todo:    result = await setTodoCompletion(input, completed: true)
        case .uncomplete_todo:  result = await setTodoCompletion(input, completed: false)
        case .complete_reminder:result = await completeReminder(input)
        case .delete_item:      result = await deleteItem(input)
        case .search_items:     result = searchItems(input)
        case .get_item:         result = getItem(input)
        case .attach_item_preview: result = attachItemPreview(input)
        case .open_url:         result = openURLTool(input)
        case .create_habit:     result = await createHabit(input)
        case .log_habit_entry:  result = await logHabitEntryTool(input)
        case .complete_habit:   result = await completeHabitTool(input)
        case .list_habits:      result = listHabitsTool(input)
        case .read_file:        result = await readFile(input)
        }
        // Audible confirmation of successful write-type actions — skip reads
        // (search/get/attach) and URL opens so we don't chime on every search.
        if !result.isError, Self.writeTools.contains(tool) {
            Sounds.play(.taskComplete)
        }
        return result
    }

    private static let writeTools: Set<OttoTools.Name> = [
        .create_todo, .create_note, .create_idea, .create_reminder, .create_bookmark,
        .update_todo, .update_note, .update_idea,
        .complete_todo, .uncomplete_todo, .complete_reminder,
        .delete_item,
        .create_habit, .log_habit_entry, .complete_habit
    ]

    // MARK: - Open URL

    /// Opens an http(s) URL in the user's default browser. Rejects non-web schemes
    /// (avoids file://, javascript:, x-apple-*, etc. being passed in by mistake
    /// or adversarial tool input).
    private func openURLTool(_ input: [String: Any]) -> ToolResult {
        guard let raw = string(input, "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return err("Missing 'url'.", summary: "Open URL failed")
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return err("Only http:// or https:// URLs are allowed (got '\(raw)').",
                       summary: "Open URL failed")
        }
        // `openURL(_:)` lives in Otto/Utilities/Theme.swift and wraps NSWorkspace.
        openURL(url)
        let reason = string(input, "reason")?.trimmingCharacters(in: .whitespaces) ?? ""
        let summary = reason.isEmpty ? "Opened \(url.host ?? raw)" : "Opened: \(reason)"
        return ok("Opened \(url.absoluteString) in default browser.", summary: summary)
    }

    // MARK: - Preview attachment

    /// Validates the referenced item exists and echoes a compact preview payload
    /// (id, type, title, snippet). The UI layer intercepts the tool_call and
    /// renders a clickable card — this result is only what Claude "sees" as feedback.
    private func attachItemPreview(_ input: [String: Any]) -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Attach preview failed")
        }
        guard let type = string(input, "type")?.lowercased() else {
            return err("Missing 'type'.", summary: "Attach preview failed")
        }
        let title: String? = {
            switch type {
            case "todo":       return appState.todos.first(where: { $0.id == id })?.title
            case "note":       return appState.notes.first(where: { $0.id == id })?.title
            case "idea":       return appState.ideas.first(where: { $0.id == id })?.title
            case "reminder":   return appState.reminders.first(where: { $0.id == id })?.title
            case "bookmark":   return appState.bookmarks.first(where: { $0.id == id })?.title
            case "meeting":    return appState.meetings.first(where: { $0.id == id })?.title
            case "email":      return appState.emails.first(where: { $0.id == id })?.subject
            case "connection": return appState.connections.first(where: { $0.id == id })?.fullName
            case "habit":      return appState.habits.first(where: { $0.id == id })?.title
            case "x_post":     return appState.xPosts.first(where: { $0.id == id }).map { "@\($0.authorUsername): \(String($0.text.prefix(60)))" }
            case "x_follower": return appState.xFollowers.first(where: { $0.id == id }).map { "\($0.displayName) (@\($0.username))" }
            case "x_dm":       return appState.xDirectMessages.first(where: { $0.id == id }).map { "DM from @\($0.senderUsername)" }
            default:           return nil
            }
        }()
        guard let title else {
            return err("No \(type) found with id \(id.uuidString).", summary: "Preview not found")
        }
        return ok(
            "Attached preview: \(type) \(id.uuidString) — \(title)",
            summary: "Preview: \(title)"
        )
    }

    // MARK: - Create

    private func createTodo(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title"), !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create todo failed")
        }
        let description = string(input, "description") ?? ""
        let priority = parsePriority(string(input, "priority")) ?? .medium
        let dueDate = parseDate(string(input, "due_date"))
        let tagNames = stringArray(input, "tags")
        let tagIds = tagNames.isEmpty ? [] : await appState.resolveTagIds(tagNames)

        let todo = Todo(
            title: title,
            description: description,
            dueDate: dueDate,
            priority: priority,
            domainTagIds: tagIds
        )
        await appState.addTodo(todo)
        return ok(
            "Created todo id=\(todo.id.uuidString) title=\(title)",
            summary: "Created todo: \(title)"
        )
    }

    private func createNote(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title"), !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create note failed")
        }
        let content = string(input, "content") ?? ""
        let category = parseCategory(string(input, "category")) ?? .personal
        let tagNames = stringArray(input, "tags")
        let tagIds = tagNames.isEmpty ? [] : await appState.resolveTagIds(tagNames)

        let note = Note(
            title: title,
            content: content,
            primaryCategory: category,
            domainTagIds: tagIds
        )
        await appState.addNote(note)
        return ok(
            "Created note id=\(note.id.uuidString) title=\(title)",
            summary: "Created note: \(title)"
        )
    }

    private func createIdea(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title"), !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create idea failed")
        }
        let content = string(input, "content") ?? ""
        let category = parseCategory(string(input, "category")) ?? .personal
        let tagNames = stringArray(input, "tags")
        let tagIds = tagNames.isEmpty ? [] : await appState.resolveTagIds(tagNames)

        let idea = Idea(
            title: title,
            content: content,
            primaryCategory: category,
            domainTagIds: tagIds
        )
        await appState.addIdea(idea)
        return ok(
            "Created idea id=\(idea.id.uuidString) title=\(title)",
            summary: "Created idea: \(title)"
        )
    }

    private func createReminder(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title"), !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create reminder failed")
        }
        guard let date = parseDate(string(input, "reminder_date")) else {
            return err("Missing or invalid 'reminder_date' (expected ISO8601).", summary: "Create reminder failed")
        }
        let reminder = Reminder(title: title, reminderDate: date)
        await appState.addReminder(reminder)
        return ok(
            "Created reminder id=\(reminder.id.uuidString) title=\(title) at=\(ISO8601DateFormatter().string(from: date))",
            summary: "Created reminder: \(title)"
        )
    }

    private func createBookmark(_ input: [String: Any]) async -> ToolResult {
        guard let url = string(input, "url"), !url.isEmpty else {
            return err("Missing required 'url'.", summary: "Create bookmark failed")
        }
        let title = string(input, "title") ?? url
        let description = string(input, "description") ?? ""
        let bookmark = Bookmark(title: title, url: url, description: description)
        await appState.addBookmark(bookmark)
        return ok(
            "Created bookmark id=\(bookmark.id.uuidString) url=\(url)",
            summary: "Bookmarked: \(title)"
        )
    }

    // MARK: - Update

    private func updateTodo(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update todo failed")
        }
        guard var todo = appState.todos.first(where: { $0.id == id }) else {
            return err("No todo with id \(id.uuidString).", summary: "Update todo failed")
        }
        var changed = false
        if let t = string(input, "title"), !t.isEmpty { todo.title = t; changed = true }
        if let d = string(input, "description") { todo.description = d; changed = true }
        if let p = parsePriority(string(input, "priority")) { todo.priority = p; changed = true }
        if input["due_date"] != nil {
            let raw = string(input, "due_date") ?? ""
            todo.dueDate = raw.isEmpty ? nil : parseDate(raw)
            changed = true
        }
        guard changed else {
            return err("No fields provided to update.", summary: "Update todo failed")
        }
        todo.updatedAt = Date()
        await appState.updateTodo(todo)
        return ok("Updated todo \(todo.id.uuidString).", summary: "Updated todo: \(todo.title)")
    }

    private func updateNote(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update note failed")
        }
        guard var note = appState.notes.first(where: { $0.id == id }) else {
            return err("No note with id \(id.uuidString).", summary: "Update note failed")
        }
        var changed = false
        if let t = string(input, "title"), !t.isEmpty { note.title = t; changed = true }
        if let c = string(input, "content") { note.content = c; changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update note failed") }
        note.updatedAt = Date()
        await appState.updateNote(note)
        return ok("Updated note \(note.id.uuidString).", summary: "Updated note: \(note.title)")
    }

    private func updateIdea(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update idea failed")
        }
        guard var idea = appState.ideas.first(where: { $0.id == id }) else {
            return err("No idea with id \(id.uuidString).", summary: "Update idea failed")
        }
        var changed = false
        if let t = string(input, "title"), !t.isEmpty { idea.title = t; changed = true }
        if let c = string(input, "content") { idea.content = c; changed = true }
        if let s = string(input, "status"), let status = Idea.Status.allCases.first(where: { $0.rawValue.lowercased() == s.lowercased() }) {
            idea.status = status; changed = true
        }
        guard changed else { return err("No fields provided to update.", summary: "Update idea failed") }
        idea.updatedAt = Date()
        await appState.updateIdea(idea)
        return ok("Updated idea \(idea.id.uuidString).", summary: "Updated idea: \(idea.title)")
    }

    // MARK: - Complete / uncomplete

    private func setTodoCompletion(_ input: [String: Any], completed: Bool) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Todo status change failed")
        }
        guard let todo = appState.todos.first(where: { $0.id == id }) else {
            return err("No todo with id \(id.uuidString).", summary: "Todo status change failed")
        }
        if todo.isCompleted != completed {
            await appState.toggleTodo(todo)
        }
        let verb = completed ? "Completed" : "Reopened"
        return ok("\(verb) todo \(todo.id.uuidString).", summary: "\(verb) todo: \(todo.title)")
    }

    private func completeReminder(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Complete reminder failed")
        }
        guard let reminder = appState.reminders.first(where: { $0.id == id }) else {
            return err("No reminder with id \(id.uuidString).", summary: "Complete reminder failed")
        }
        await appState.completeReminder(reminder)
        return ok("Completed reminder \(reminder.id.uuidString).", summary: "Completed reminder: \(reminder.title)")
    }

    // MARK: - Delete

    private func deleteItem(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Delete failed")
        }
        guard let type = string(input, "type")?.lowercased() else {
            return err("Missing 'type'.", summary: "Delete failed")
        }
        switch type {
        case "todo":
            guard let t = appState.todos.first(where: { $0.id == id }) else {
                return err("No todo with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteTodo(t)
            return ok("Deleted todo \(id.uuidString).", summary: "Deleted todo: \(t.title)")
        case "note":
            guard let n = appState.notes.first(where: { $0.id == id }) else {
                return err("No note with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteNote(n)
            return ok("Deleted note \(id.uuidString).", summary: "Deleted note: \(n.title)")
        case "idea":
            guard let i = appState.ideas.first(where: { $0.id == id }) else {
                return err("No idea with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteIdea(i)
            return ok("Deleted idea \(id.uuidString).", summary: "Deleted idea: \(i.title)")
        case "reminder":
            guard let r = appState.reminders.first(where: { $0.id == id }) else {
                return err("No reminder with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteReminder(r)
            return ok("Deleted reminder \(id.uuidString).", summary: "Deleted reminder: \(r.title)")
        case "bookmark":
            guard let b = appState.bookmarks.first(where: { $0.id == id }) else {
                return err("No bookmark with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteBookmark(b)
            return ok("Deleted bookmark \(id.uuidString).", summary: "Deleted bookmark: \(b.title)")
        case "habit":
            guard let h = appState.habits.first(where: { $0.id == id }) else {
                return err("No habit with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteHabit(h)
            return ok("Deleted habit \(id.uuidString).", summary: "Deleted habit: \(h.title)")
        case "file":
            guard let f = appState.files.first(where: { $0.id == id }) else {
                return err("No file with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteFile(f)
            return ok("Deleted file \(id.uuidString).", summary: "Deleted file: \(f.name)")
        default:
            return err("Unsupported delete type: \(type).", summary: "Delete failed")
        }
    }

    // MARK: - Search / get

    private func searchItems(_ input: [String: Any]) -> ToolResult {
        // Text query is now optional — omit to list-by-date/filter.
        let needle: String? = {
            guard let q = string(input, "query")?.trimmingCharacters(in: .whitespaces), !q.isEmpty
            else { return nil }
            return q.lowercased()
        }()
        let types: Set<String> = {
            if let arr = input["types"] as? [String], !arr.isEmpty { return Set(arr.map { $0.lowercased() }) }
            return ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "file", "x_post", "x_follower", "x_dm"]
        }()
        let limit = max(1, min((input["limit"] as? Int) ?? 20, 100))
        let sortKey = (string(input, "sort") ?? "recent").lowercased()
        let since = parseDate(string(input, "since"))
        let until = parseDate(string(input, "until"))
        let includeCompleted = (input["include_completed"] as? Bool) ?? true
        let df = ISO8601DateFormatter()

        struct Match {
            let id: UUID
            let type: String
            let title: String
            let snippet: String
            /// Primary date used for ranking/filtering. Type-specific (email=receivedDate, etc.).
            let date: Date
            /// Optional due/reminder date used by the `due_soonest` sort.
            let dueDate: Date?
        }
        var matches: [Match] = []

        // Text-match helper. Returns true when no query or when any of the candidate
        // fields contains the needle (case-insensitive).
        func textMatches(_ candidates: [String]) -> Bool {
            guard let needle else { return true }
            for c in candidates where c.lowercased().contains(needle) { return true }
            return false
        }

        if types.contains("todo") {
            for t in appState.todos {
                if !includeCompleted, t.isCompleted { continue }
                if !textMatches([t.title, t.description]) { continue }
                matches.append(.init(id: t.id, type: "todo", title: t.title,
                                     snippet: String(t.description.prefix(140)),
                                     date: t.updatedAt, dueDate: t.dueDate))
            }
        }
        if types.contains("note") {
            for n in appState.notes where textMatches([n.title, n.content]) {
                matches.append(.init(id: n.id, type: "note", title: n.title,
                                     snippet: String(n.content.prefix(140)),
                                     date: n.updatedAt, dueDate: nil))
            }
        }
        if types.contains("idea") {
            for i in appState.ideas where textMatches([i.title, i.content]) {
                matches.append(.init(id: i.id, type: "idea", title: i.title,
                                     snippet: String(i.content.prefix(140)),
                                     date: i.updatedAt, dueDate: nil))
            }
        }
        if types.contains("reminder") {
            for r in appState.reminders {
                if !includeCompleted, r.isCompleted { continue }
                if !textMatches([r.title]) { continue }
                matches.append(.init(id: r.id, type: "reminder", title: r.title,
                                     snippet: df.string(from: r.reminderDate),
                                     date: r.reminderDate, dueDate: r.reminderDate))
            }
        }
        if types.contains("bookmark") {
            for b in appState.bookmarks where textMatches([b.title, b.url, b.description]) {
                matches.append(.init(id: b.id, type: "bookmark", title: b.title,
                                     snippet: b.url,
                                     date: b.updatedAt, dueDate: nil))
            }
        }
        if types.contains("meeting") {
            for m in appState.meetings where textMatches([m.title, m.overview, m.content]) {
                matches.append(.init(id: m.id, type: "meeting", title: m.title,
                                     snippet: String(m.overview.prefix(140)),
                                     date: m.meetingDate, dueDate: nil))
            }
        }
        if types.contains("email") {
            for e in appState.emails where textMatches([e.subject, e.body, e.displaySender]) {
                matches.append(.init(id: e.id, type: "email", title: e.subject,
                                     snippet: "From: \(e.displaySender)",
                                     date: e.receivedDate, dueDate: nil))
            }
        }
        if types.contains("connection") {
            for c in appState.connections where textMatches([c.fullName, c.headline, c.company]) {
                matches.append(.init(id: c.id, type: "connection", title: c.fullName,
                                     snippet: c.displayInfo,
                                     date: c.updatedAt, dueDate: nil))
            }
        }
        if types.contains("file") {
            for f in appState.files {
                // Match against name, notes, tags, and extracted-text snippet.
                let preview = f.extractedText.map { String($0.prefix(400)) } ?? ""
                if !textMatches([f.name, f.notes, preview] + f.tags) { continue }
                let snippet: String = {
                    if let preview = f.extractedText, !preview.isEmpty {
                        return String(preview.prefix(140))
                    }
                    return "\(f.fileType.displayName) · \(f.formattedSize)"
                }()
                matches.append(.init(id: f.id, type: "file", title: f.name,
                                     snippet: snippet,
                                     date: f.updatedAt, dueDate: nil))
            }
        }
        if types.contains("x_post") {
            for p in appState.xPosts where textMatches([p.text, p.authorDisplayName, p.authorUsername]) {
                let title = "@\(p.authorUsername): \(String(p.text.prefix(60)))"
                matches.append(.init(id: p.id, type: "x_post", title: title,
                                     snippet: String(p.text.prefix(140)),
                                     date: p.createdAt, dueDate: nil))
            }
        }
        if types.contains("x_follower") {
            for fol in appState.xFollowers where textMatches([fol.displayName, fol.username, fol.bio]) {
                let title = "\(fol.displayName) (@\(fol.username))"
                let snippet = fol.bio.isEmpty
                    ? "\(fol.followersCount) followers\(fol.isMutual ? " · mutual" : "")"
                    : String(fol.bio.prefix(140))
                matches.append(.init(id: fol.id, type: "x_follower", title: title,
                                     snippet: snippet,
                                     date: fol.syncUpdatedAt, dueDate: nil))
            }
        }
        if types.contains("x_dm") {
            for dm in appState.xDirectMessages where textMatches([dm.text, dm.senderDisplayName, dm.senderUsername]) {
                let title = "DM from @\(dm.senderUsername): \(String(dm.text.prefix(50)))"
                matches.append(.init(id: dm.id, type: "x_dm", title: title,
                                     snippet: String(dm.text.prefix(140)),
                                     date: dm.createdAt, dueDate: nil))
            }
        }

        // Date-range filters on the primary date.
        if let since { matches.removeAll { $0.date < since } }
        if let until { matches.removeAll { $0.date > until } }

        // Sort.
        switch sortKey {
        case "oldest":
            matches.sort { $0.date < $1.date }
        case "title":
            matches.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "due_soonest":
            // Items with a due date first (ascending); items without a due date after,
            // falling back to reverse-chronological on their primary date.
            matches.sort { a, b in
                switch (a.dueDate, b.dueDate) {
                case (let ad?, let bd?): return ad < bd
                case (_?, nil):          return true
                case (nil, _?):          return false
                case (nil, nil):         return a.date > b.date
                }
            }
        default: // "recent"
            matches.sort { $0.date > $1.date }
        }

        let top = Array(matches.prefix(limit))

        var out: [[String: Any]] = []
        for m in top {
            out.append([
                "id": m.id.uuidString,
                "type": m.type,
                "title": m.title,
                "snippet": m.snippet,
                "date": df.string(from: m.date)
            ])
        }
        let payload: [String: Any] = [
            "query": needle ?? "",
            "sort": sortKey,
            "total_matches": matches.count,
            "returned": top.count,
            "items": out
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let summary: String = {
            let count = matches.count
            let noun = count == 1 ? "match" : "matches"
            if let needle { return "Found \(count) \(noun) for '\(needle)'" }
            let typeLabel = types.count == 1 ? (types.first ?? "item") + "s" : "items"
            return "Listed \(count) \(typeLabel) (\(sortKey))"
        }()
        return ok(text, summary: summary)
    }

    private func getItem(_ input: [String: Any]) -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Fetch failed")
        }
        guard let type = string(input, "type")?.lowercased() else {
            return err("Missing 'type'.", summary: "Fetch failed")
        }
        let df = ISO8601DateFormatter()
        var payload: [String: Any]?
        switch type {
        case "todo":
            if let t = appState.todos.first(where: { $0.id == id }) {
                payload = [
                    "id": t.id.uuidString, "type": "todo",
                    "title": t.title, "description": t.description,
                    "priority": t.priority.displayName, "is_completed": t.isCompleted,
                    "due_date": t.dueDate.map { df.string(from: $0) } ?? NSNull(),
                    "created_at": df.string(from: t.createdAt),
                    "updated_at": df.string(from: t.updatedAt)
                ]
            }
        case "note":
            if let n = appState.notes.first(where: { $0.id == id }) {
                payload = [
                    "id": n.id.uuidString, "type": "note",
                    "title": n.title, "content": n.content,
                    "category": n.primaryCategory.rawValue,
                    "created_at": df.string(from: n.createdAt),
                    "updated_at": df.string(from: n.updatedAt)
                ]
            }
        case "idea":
            if let i = appState.ideas.first(where: { $0.id == id }) {
                payload = [
                    "id": i.id.uuidString, "type": "idea",
                    "title": i.title, "content": i.content,
                    "status": i.status.rawValue,
                    "category": i.primaryCategory.rawValue,
                    "created_at": df.string(from: i.createdAt),
                    "updated_at": df.string(from: i.updatedAt)
                ]
            }
        case "reminder":
            if let r = appState.reminders.first(where: { $0.id == id }) {
                payload = [
                    "id": r.id.uuidString, "type": "reminder",
                    "title": r.title,
                    "reminder_date": df.string(from: r.reminderDate),
                    "is_completed": r.isCompleted
                ]
            }
        case "bookmark":
            if let b = appState.bookmarks.first(where: { $0.id == id }) {
                payload = [
                    "id": b.id.uuidString, "type": "bookmark",
                    "title": b.title, "url": b.url,
                    "description": b.description,
                    "media_type": b.mediaType.rawValue,
                    "is_read": b.isRead
                ]
            }
        case "meeting":
            if let m = appState.meetings.first(where: { $0.id == id }) {
                payload = [
                    "id": m.id.uuidString, "type": "meeting",
                    "title": m.title,
                    "date": df.string(from: m.meetingDate),
                    "overview": m.overview,
                    "action_items": m.actionItems,
                    "participants": m.participants,
                    "content": String(m.content.prefix(4000))
                ]
            }
        case "email":
            if let e = appState.emails.first(where: { $0.id == id }) {
                payload = [
                    "id": e.id.uuidString, "type": "email",
                    "subject": e.subject,
                    "sender": e.displaySender,
                    "recipients": e.recipients,
                    "received_date": df.string(from: e.receivedDate),
                    "body": String(e.body.prefix(4000))
                ]
            }
        case "connection":
            if let c = appState.connections.first(where: { $0.id == id }) {
                payload = [
                    "id": c.id.uuidString, "type": "connection",
                    "full_name": c.fullName,
                    "headline": c.headline,
                    "company": c.company,
                    "location": c.location,
                    "email": c.email ?? "",
                    "notes": c.notes
                ]
            }
        case "file":
            if let f = appState.files.first(where: { $0.id == id }) {
                payload = [
                    "id": f.id.uuidString, "type": "file",
                    "name": f.name,
                    "file_type": f.fileType.rawValue,
                    "extension": f.fileExtension,
                    "size_bytes": f.fileSize,
                    "formatted_size": f.formattedSize,
                    "tags": f.tags,
                    "notes": f.notes,
                    "has_extracted_text": f.extractedText != nil,
                    "text_preview": f.extractedText.map { String($0.prefix(1000)) } ?? "",
                    "hint": "Use `read_file` with this id to fetch the full text content or the staged local path."
                ]
            }
        case "x_post":
            if let p = appState.xPosts.first(where: { $0.id == id }) {
                payload = [
                    "id": p.id.uuidString, "type": "x_post",
                    "x_post_id": p.xPostId,
                    "text": p.text,
                    "author_username": p.authorUsername,
                    "author_display_name": p.authorDisplayName,
                    "created_at": df.string(from: p.createdAt),
                    "like_count": p.likeCount,
                    "retweet_count": p.retweetCount,
                    "reply_count": p.replyCount,
                    "is_retweet": p.isRetweet,
                    "is_reply": p.isReply,
                    "media_urls": p.mediaUrls,
                    "url": "https://x.com/\(p.authorUsername)/status/\(p.xPostId)"
                ]
            }
        case "x_follower":
            if let fol = appState.xFollowers.first(where: { $0.id == id }) {
                payload = [
                    "id": fol.id.uuidString, "type": "x_follower",
                    "username": fol.username,
                    "display_name": fol.displayName,
                    "bio": fol.bio,
                    "followers_count": fol.followersCount,
                    "following_count": fol.followingCount,
                    "is_mutual": fol.isMutual,
                    "profile_image_url": fol.profileImageUrl ?? "",
                    "linked_connection_id": fol.linkedConnectionId?.uuidString ?? "",
                    "url": "https://x.com/\(fol.username)"
                ]
            }
        case "x_dm":
            if let dm = appState.xDirectMessages.first(where: { $0.id == id }) {
                payload = [
                    "id": dm.id.uuidString, "type": "x_dm",
                    "x_message_id": dm.xMessageId,
                    "text": dm.text,
                    "sender_username": dm.senderUsername,
                    "sender_display_name": dm.senderDisplayName,
                    "sender_id": dm.senderId,
                    "recipient_id": dm.recipientId,
                    "conversation_id": dm.conversationId,
                    "created_at": df.string(from: dm.createdAt)
                ]
            }
        default:
            return err("Unsupported type: \(type).", summary: "Fetch failed")
        }
        guard let payload else {
            return err("No \(type) with id \(id.uuidString).", summary: "Fetch failed")
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let title = (payload["title"] as? String) ?? (payload["full_name"] as? String) ?? (payload["subject"] as? String) ?? (payload["name"] as? String) ?? "item"
        return ok(text, summary: "Fetched \(type): \(title)")
    }

    // MARK: - Files

    /// Read a file the user imported into Otto: returns the extracted text
    /// (already populated at import time by `FileStorageService`) plus an
    /// absolute path to the file binary on disk. The agent CLIs (Claude
    /// Code, Codex) run with full FS access in this app, so they can call
    /// their built-in `Read` tool with the path — handy for images (Claude's
    /// Read is multimodal) and for PDFs whose extracted text is patchy.
    private func readFile(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "read_file failed")
        }
        guard let file = appState.files.first(where: { $0.id == id }) else {
            return err("No file with id \(id.uuidString). Use `search_items` with type=\"file\" to discover ids.",
                       summary: "File not found")
        }
        let maxChars: Int = {
            let raw = (input["max_chars"] as? Int) ?? (Int(string(input, "max_chars") ?? "") ?? 20_000)
            return min(max(raw, 1), 200_000)
        }()

        let fileURL = await FileStorageService.shared.getFileURL(for: file)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let textBody: String = {
            guard let extracted = file.extractedText, !extracted.isEmpty else { return "" }
            if extracted.count <= maxChars { return extracted }
            return String(extracted.prefix(maxChars)) + "\n\n[truncated — \(extracted.count - maxChars) more chars; raise max_chars or read the file directly at the path below]"
        }()

        let hint: String
        switch file.fileType {
        case .image:
            hint = "Image OCR text shown above. For finer visual detail, call the built-in `Read` tool with the absolute path — Claude Code's Read is multimodal and can analyse the image natively."
        case .excel:
            hint = "Excel text extraction is not supported natively. Use the built-in `Read` tool with the absolute path if you need the binary; otherwise ask the user to export as CSV."
        case .pdf:
            hint = "PDF text shown above. For layout-sensitive content, call the built-in `Read` tool with the absolute path."
        case .csv, .text:
            hint = "Full text above. Use the built-in `Grep` tool on the path for large files."
        }

        let payload: [String: Any] = [
            "id": file.id.uuidString,
            "name": file.name,
            "file_type": file.fileType.rawValue,
            "extension": file.fileExtension,
            "size_bytes": file.fileSize,
            "formatted_size": file.formattedSize,
            "path": fileURL.path,
            "binary_exists": exists,
            "has_extracted_text": file.extractedText != nil,
            "extracted_text_chars_total": file.extractedText?.count ?? 0,
            "extracted_text": textBody,
            "hint": hint
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ok(text, summary: "Read file: \(file.name)")
    }

    // MARK: - Habits

    private func createHabit(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title")?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create habit failed")
        }
        let kind = parseHabitKind(string(input, "kind")) ?? .binary
        let unit = string(input, "unit").flatMap { $0.isEmpty ? nil : $0 }
        let target: Double = {
            if let n = input["daily_target"] as? Double { return n }
            if let n = input["daily_target"] as? Int    { return Double(n) }
            if let s = string(input, "daily_target"), let n = Double(s) { return n }
            return kind == .binary ? 1 : 1
        }()
        let frequency = parseFrequency(input)
        let category = parseHabitCategory(string(input, "category")) ?? .custom
        let icon = string(input, "icon")?.trimmingCharacters(in: .whitespaces) ?? defaultIcon(for: category, kind: kind)
        let color = parseColorTag(string(input, "color")) ?? .cyan
        let notes = string(input, "notes") ?? ""

        let habit = Habit(
            title: title,
            notes: notes,
            iconName: icon.isEmpty ? "checkmark.circle" : icon,
            colorTag: color,
            category: category,
            kind: kind,
            unit: unit,
            dailyTarget: max(0, target),
            frequency: frequency
        )
        await appState.addHabit(habit)
        let unitText = unit.map { " \($0)" } ?? ""
        let targetText = kind == .binary ? "" : " · \(formatNumber(target))\(unitText)/day"
        return ok(
            "Created habit id=\(habit.id.uuidString) title=\(title) kind=\(kind.rawValue)\(targetText)",
            summary: "Created habit: \(title)\(targetText)"
        )
    }

    private func logHabitEntryTool(_ input: [String: Any]) async -> ToolResult {
        guard let raw = string(input, "habit")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return err("Missing required 'habit' (id or name).", summary: "Log habit failed")
        }
        guard let habit = resolveHabit(raw) else {
            return err(
                "No habit matches '\(raw)'. Active habits: \(habitNames()).",
                summary: "Log habit failed"
            )
        }
        let value: Double = {
            if let n = input["value"] as? Double { return n }
            if let n = input["value"] as? Int    { return Double(n) }
            if let s = string(input, "value"), let n = Double(s) { return n }
            return 1
        }()
        let date = parseDate(string(input, "date")) ?? Date()
        let note = string(input, "note")
        await appState.logHabitEntry(habitId: habit.id, value: value, date: date, note: note)
        let unit = habit.unit.map { " \($0)" } ?? ""
        let progress = (appState.habits.first(where: { $0.id == habit.id })?.progress(on: date)) ?? value
        let target = habit.dailyTarget
        return ok(
            "Logged \(formatNumber(value))\(unit) to '\(habit.title)'. Today: \(formatNumber(progress))/\(formatNumber(target))\(unit).",
            summary: "Logged \(formatNumber(value))\(unit) → \(habit.title)"
        )
    }

    private func completeHabitTool(_ input: [String: Any]) async -> ToolResult {
        guard let raw = string(input, "habit")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return err("Missing required 'habit' (id or name).", summary: "Complete habit failed")
        }
        guard let habit = resolveHabit(raw) else {
            return err(
                "No habit matches '\(raw)'. Active habits: \(habitNames()).",
                summary: "Complete habit failed"
            )
        }
        await appState.completeHabitToday(habitId: habit.id)
        let updated = appState.habits.first(where: { $0.id == habit.id }) ?? habit
        let streak = updated.currentStreak()
        return ok(
            "Completed habit '\(habit.title)' for today. Current streak: \(streak).",
            summary: "Completed: \(habit.title) · streak \(streak)"
        )
    }

    private func listHabitsTool(_ input: [String: Any]) -> ToolResult {
        let includeArchived = (input["include_archived"] as? Bool) ?? false
        let source = includeArchived ? appState.habits : appState.habits.filter { !$0.isArchived }
        var rows: [[String: Any]] = []
        for h in source {
            let progress = h.progress(on: Date())
            rows.append([
                "id": h.id.uuidString,
                "title": h.title,
                "kind": h.kind.rawValue,
                "unit": h.unit ?? "",
                "daily_target": h.dailyTarget,
                "today_progress": progress,
                "is_met_today": h.isMet(on: Date()),
                "current_streak": h.currentStreak(),
                "rate_7d": h.completionRate(lastDays: 7),
                "frequency": h.frequency.displayName,
                "is_archived": h.isArchived
            ])
        }
        let payload: [String: Any] = [
            "count": rows.count,
            "habits": rows
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ok(text, summary: "Listed \(rows.count) habit\(rows.count == 1 ? "" : "s")")
    }

    // MARK: - Habit helpers

    /// Resolve a habit reference that might be a UUID string or a fuzzy name.
    private func resolveHabit(_ raw: String) -> Habit? {
        if let uuid = UUID(uuidString: raw),
           let byId = appState.habits.first(where: { $0.id == uuid }) {
            return byId
        }
        return appState.findHabit(byName: raw)
    }

    private func habitNames() -> String {
        let active = appState.habits.filter { !$0.isArchived }
        if active.isEmpty { return "(none)" }
        return active.map { "'\($0.title)'" }.joined(separator: ", ")
    }

    private func parseHabitKind(_ s: String?) -> Habit.Kind? {
        guard let s = s?.lowercased() else { return nil }
        return Habit.Kind.allCases.first(where: { $0.rawValue == s })
    }

    private func parseHabitCategory(_ s: String?) -> Habit.Category? {
        guard let s = s?.lowercased() else { return nil }
        return Habit.Category.allCases.first(where: { $0.rawValue.lowercased() == s })
    }

    private func parseColorTag(_ s: String?) -> Habit.ColorTag? {
        guard let s = s?.lowercased() else { return nil }
        return Habit.ColorTag.allCases.first(where: { $0.rawValue.lowercased() == s })
    }

    private func parseFrequency(_ input: [String: Any]) -> Habit.Frequency {
        let raw = (string(input, "frequency") ?? "daily").lowercased()
        switch raw {
        case "weekdays":
            let names = stringArray(input, "weekdays").map { $0.lowercased() }
            let map: [String: Habit.Weekday] = [
                "sun": .sun, "mon": .mon, "tue": .tue, "wed": .wed,
                "thu": .thu, "fri": .fri, "sat": .sat
            ]
            let days = Set(names.compactMap { map[$0] })
            return days.isEmpty ? .daily : .weekdays(days)
        case "weekly":
            let n: Int = {
                if let i = input["weekly_count"] as? Int { return i }
                if let s = string(input, "weekly_count"), let i = Int(s) { return i }
                return 1
            }()
            return .weeklyCount(max(1, min(7, n)))
        default:
            return .daily
        }
    }

    private func defaultIcon(for category: Habit.Category, kind: Habit.Kind) -> String {
        switch category {
        case .health:        return "heart"
        case .fitness:       return "figure.run"
        case .learning:      return "book"
        case .mindfulness:   return "brain.head.profile"
        case .personalCare:  return "sparkles"
        case .nutrition:     return "fork.knife"
        case .productivity:  return "checkmark.square"
        case .custom:        return "checkmark.circle"
        }
    }

    private func formatNumber(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.1f", n)
    }

    // MARK: - Parsing helpers

    private func string(_ input: [String: Any], _ key: String) -> String? {
        (input[key] as? String)
    }

    private func stringArray(_ input: [String: Any], _ key: String) -> [String] {
        (input[key] as? [String]) ?? []
    }

    private func parseUUID(_ s: String?) -> UUID? {
        guard let s, !s.isEmpty else { return nil }
        return UUID(uuidString: s)
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // Fall back to date-only
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df.date(from: s)
    }

    private func parsePriority(_ s: String?) -> Todo.Priority? {
        guard let s = s?.lowercased() else { return nil }
        switch s {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "urgent": return .urgent
        default: return nil
        }
    }

    private func parseCategory(_ s: String?) -> PrimaryCategory? {
        guard let s = s?.lowercased() else { return nil }
        switch s {
        case "work": return .work
        case "personal": return .personal
        case "hobby": return .hobby
        default: return nil
        }
    }

    // MARK: - Result helpers

    private func ok(_ content: String, summary: String) -> ToolResult {
        ToolResult(content: content, isError: false, summary: summary)
    }

    private func err(_ content: String, summary: String) -> ToolResult {
        ToolResult(content: content, isError: true, summary: summary)
    }
}

// MARK: - Helpers

private extension Optional where Wrapped == String {
    /// Treat empty / whitespace-only strings as missing. Tool inputs from the
    /// LLM often arrive as `""` where the field should be omitted — this lets
    /// call sites use a single fluent check.
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}

private extension String {
    var nonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
