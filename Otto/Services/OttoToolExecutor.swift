import Foundation
import AppKit

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
            // Generated per-tab tools (create_<slug> / update_<slug>) aren't
            // compile-time Name cases — route them by the owning custom tab.
            if let (action, tab) = OttoTools.customTabTool(named: name, tabs: appState.customTabs) {
                let result: ToolResult
                switch action {
                case .create: result = await createCustomTabRecord(tab: tab, input)
                case .update: result = await updateCustomTabRecord(tab: tab, input)
                }
                if !result.isError { Sounds.play(.taskComplete) }
                return result
            }
            return err("Unknown tool: \(name)", summary: "Unknown tool \(name)")
        }
        let result: ToolResult
        switch tool {
        case .create_todo:      result = await createTodo(input)
        case .create_note:      result = await createNote(input)
        case .create_idea:      result = await createIdea(input)
        case .create_reminder:  result = await createReminder(input)
        case .create_bookmark:  result = await createBookmark(input)
        case .create_meeting:   result = await createMeeting(input)
        case .update_todo:      result = await updateTodo(input)
        case .update_note:      result = await updateNote(input)
        case .update_idea:      result = await updateIdea(input)
        case .update_reminder:  result = await updateReminder(input)
        case .update_bookmark:  result = await updateBookmark(input)
        case .update_meeting:   result = await updateMeeting(input)
        case .create_network_entry: result = await createNetworkEntry(input)
        case .update_network_entry: result = await updateNetworkEntry(input)
        case .create_company:   result = await createCompany(input)
        case .update_company:   result = await updateCompany(input)
        case .create_event:     result = await createEvent(input)
        case .update_event:     result = await updateEvent(input)
        case .create_community: result = await createCommunity(input)
        case .update_community: result = await updateCommunity(input)
        case .complete_todo:    result = await setTodoCompletion(input, completed: true)
        case .uncomplete_todo:  result = await setTodoCompletion(input, completed: false)
        case .complete_reminder:result = await completeReminder(input)
        case .delete_item:      result = await deleteItem(input)
        case .search_items:     result = searchItems(input)
        case .grep_data:        result = grepData(input)
        case .get_item:         result = getItem(input)
        case .attach_item_preview: result = attachItemPreview(input)
        case .visualize:        result = renderVisualization(input)
        case .open_url:         result = openURLTool(input)
        case .create_habit:     result = await createHabit(input)
        case .update_habit:     result = await updateHabitTool(input)
        case .log_habit_entry:  result = await logHabitEntryTool(input)
        case .complete_habit:   result = await completeHabitTool(input)
        case .list_habits:      result = listHabitsTool(input)
        case .read_file:        result = await readFile(input)
        case .create_file:      result = await createFile(input)
        case .genmedia_search_models:     result = await genmediaSearchModels(input)
        case .genmedia_get_model_schema:  result = await genmediaGetModelSchema(input)
        case .genmedia_run:               result = await genmediaRun(input)
        case .genmedia_upload_file:       result = await genmediaUploadFile(input)
        case .create_tab:        result = await createTab(input)
        case .update_tab:        result = await updateTab(input)
        case .get_tab:           result = getTab(input)
        case .set_tab_blocks:    result = await setTabBlocks(input)
        case .update_tab_block:  result = await updateTabBlock(input)
        case .add_tab_records:   result = await addTabRecords(input)
        case .update_tab_record: result = await updateTabRecordGeneric(input)
        }
        // Audible confirmation of successful write-type actions — skip reads
        // (search/get/attach) and URL opens so we don't chime on every search.
        if !result.isError, Self.writeTools.contains(tool) {
            Sounds.play(.taskComplete)
        }
        return result
    }

    private static let writeTools: Set<OttoTools.Name> = [
        .create_todo, .create_note, .create_idea, .create_reminder, .create_bookmark, .create_meeting,
        .update_todo, .update_note, .update_idea,
        .update_reminder, .update_bookmark, .update_meeting,
        .create_network_entry, .update_network_entry,
        .create_company, .update_company,
        .create_event, .update_event,
        .create_community, .update_community,
        .complete_todo, .uncomplete_todo, .complete_reminder,
        .delete_item,
        .create_habit, .update_habit, .log_habit_entry, .complete_habit,
        // A successful genmedia_run lands a real artifact in the Files tab,
        // so it earns the same "thing happened" chime as the create_* tools.
        .genmedia_run,
        // Same rationale — create_file delivers a downloadable artifact.
        .create_file,
        .create_tab, .update_tab, .set_tab_blocks, .update_tab_block,
        .add_tab_records, .update_tab_record
    ]

    // MARK: - Grep data (workspace tables over MCP)

    /// Backend-agnostic access to the AgentWorkspaceExporter tables. The CLI
    /// backends get real files in their cwd; Hermes runs remotely and can't
    /// see those, so it greps the same snapshot through this tool — one call
    /// with an alternation pattern instead of a chain of search_items calls.
    private func grepData(_ input: [String: Any]) -> ToolResult {
        let file = (input["file"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = input["pattern"] as? String ?? ""
        let maxResults = min(max(input["max_results"] as? Int ?? 50, 1), 200)
        guard !file.isEmpty, !pattern.isEmpty else {
            return err("grep_data needs both `file` and `pattern`.", summary: "grep_data: missing arguments")
        }
        let out = AgentWorkspaceExporter.grep(
            file: file,
            pattern: pattern,
            maxResults: maxResults,
            appState: appState
        )
        if out.isError {
            return err(out.text, summary: "grep \(file) failed")
        }
        let noun = out.matchCount == 1 ? "match" : "matches"
        return ok(out.text, summary: "\(out.matchCount) \(noun) in \(file)")
    }

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
            case "network":    return appState.networkEntries.first(where: { $0.id == id }).map { $0.name.isEmpty ? $0.company : $0.name }
            case "company":    return appState.companies.first(where: { $0.id == id })?.name
            case "event":      return appState.events.first(where: { $0.id == id })?.name
            case "community":  return appState.communities.first(where: { $0.id == id })?.name
            case "habit":      return appState.habits.first(where: { $0.id == id })?.title
            case "file":       return appState.files.first(where: { $0.id == id })?.name
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

    // MARK: - Visualize

    /// Validates the spec and returns a sentinel. Like attach_item_preview,
    /// no UI object is created here — the chat UI renders the card straight
    /// from the tool call's input, and saved sessions rebuild it from the
    /// persisted `.toolUse` block.
    private func renderVisualization(_ input: [String: Any]) -> ToolResult {
        do {
            let spec = try VisualizationSpec.parse(input)
            let label = spec.title ?? spec.kind.displayName
            return ok(
                "Rendered \(spec.kind.rawValue) visualization — \(label). It is displayed inline in the chat; don't repeat its data in prose.",
                summary: "Visualization: \(label)"
            )
        } catch let e as VisualizationSpec.ParseError {
            return err("Invalid visualization: \(e.message)", summary: "Visualization failed")
        } catch {
            return err("Invalid visualization payload.", summary: "Visualization failed")
        }
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

    private func createMeeting(_ input: [String: Any]) async -> ToolResult {
        guard let title = string(input, "title")?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else {
            return err("Missing required 'title'.", summary: "Create meeting failed")
        }
        let content = string(input, "content") ?? ""
        let overview = string(input, "overview") ?? ""
        let actionItems = string(input, "action_items") ?? ""
        let participants = stringArray(input, "participants")
        let organizer = string(input, "organizer") ?? ""
        let durationMinutes: Int = {
            if let n = input["duration_minutes"] as? Int { return n }
            if let n = input["duration_minutes"] as? Double { return Int(n) }
            if let s = string(input, "duration_minutes"), let n = Int(s) { return n }
            return 0
        }()
        let meetingDate = parseDate(string(input, "meeting_date")) ?? Date()
        let tagNames = stringArray(input, "tags")
        let tagIds = tagNames.isEmpty ? [] : await appState.resolveTagIds(tagNames)

        let meeting = Meeting(
            title: title,
            content: content,
            overview: overview,
            actionItems: actionItems,
            participants: participants,
            organizer: organizer,
            duration: max(0, durationMinutes) * 60,
            meetingDate: meetingDate,
            domainTagIds: tagIds
        )
        await appState.addMeeting(meeting)
        return ok(
            "Created meeting id=\(meeting.id.uuidString) title=\(title) date=\(ISO8601DateFormatter().string(from: meetingDate))",
            summary: "Created meeting: \(title)"
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

    private func updateReminder(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update reminder failed")
        }
        guard var reminder = appState.reminders.first(where: { $0.id == id }) else {
            return err("No reminder with id \(id.uuidString).", summary: "Update reminder failed")
        }
        var changed = false
        if let t = string(input, "title").nonEmpty { reminder.title = t; changed = true }
        if let raw = string(input, "reminder_date").nonEmpty {
            guard let date = parseDate(raw) else {
                return err("Invalid 'reminder_date' (expected ISO8601).", summary: "Update reminder failed")
            }
            reminder.reminderDate = date
            // A moved reminder should fire again even if the old time passed.
            reminder.isTriggered = false
            changed = true
        }
        guard changed else { return err("No fields provided to update.", summary: "Update reminder failed") }
        await appState.updateReminder(reminder)
        return ok(
            "Updated reminder \(reminder.id.uuidString) — fires \(ISO8601DateFormatter().string(from: reminder.reminderDate)).",
            summary: "Updated reminder: \(reminder.title)"
        )
    }

    private func updateBookmark(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update bookmark failed")
        }
        guard var bookmark = appState.bookmarks.first(where: { $0.id == id }) else {
            return err("No bookmark with id \(id.uuidString).", summary: "Update bookmark failed")
        }
        var changed = false
        if let t = string(input, "title").nonEmpty { bookmark.title = t; changed = true }
        if let u = string(input, "url").nonEmpty { bookmark.url = u; changed = true }
        if let d = string(input, "description") { bookmark.description = d; changed = true }
        if let m = parseMediaType(string(input, "media_type")) { bookmark.mediaType = m; changed = true }
        if let r = input["is_read"] as? Bool { bookmark.isRead = r; changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update bookmark failed") }
        await appState.updateBookmark(bookmark)
        return ok("Updated bookmark \(bookmark.id.uuidString).", summary: "Updated bookmark: \(bookmark.title)")
    }

    private func updateMeeting(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update meeting failed")
        }
        guard var meeting = appState.meetings.first(where: { $0.id == id }) else {
            return err("No meeting with id \(id.uuidString).", summary: "Update meeting failed")
        }
        var changed = false
        if let t = string(input, "title").nonEmpty { meeting.title = t; changed = true }
        if let c = string(input, "content") { meeting.content = c; changed = true }
        if let o = string(input, "overview") { meeting.overview = o; changed = true }
        if let a = string(input, "action_items") { meeting.actionItems = a; changed = true }
        if let org = string(input, "organizer") { meeting.organizer = org; changed = true }
        if input["participants"] != nil { meeting.participants = stringArray(input, "participants"); changed = true }
        if let mins = intValue(input, "duration_minutes") { meeting.duration = max(0, mins) * 60; changed = true }
        if let d = parseDate(string(input, "meeting_date")) { meeting.meetingDate = d; changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update meeting failed") }
        await appState.updateMeeting(meeting)
        return ok("Updated meeting \(meeting.id.uuidString).", summary: "Updated meeting: \(meeting.title)")
    }

    // MARK: - CRM (Network Hub / Companies / Events / Communities)

    private func createNetworkEntry(_ input: [String: Any]) async -> ToolResult {
        let name = string(input, "name").nonEmpty ?? ""
        let company = string(input, "company").nonEmpty ?? ""
        guard !name.isEmpty || !company.isEmpty else {
            return err("Provide at least 'name' or 'company'.", summary: "Create network entry failed")
        }
        let entry = NetworkEntry(
            type: parseNetworkType(string(input, "type")) ?? .other,
            company: company,
            industry: string(input, "industry") ?? "",
            name: name,
            individualType: parseIndividualType(string(input, "individual_type")) ?? .other,
            title: string(input, "title") ?? "",
            location: string(input, "location") ?? "",
            email: string(input, "email") ?? "",
            linkedin: string(input, "linkedin").nonEmpty,
            closeness: parseCloseness(string(input, "closeness")) ?? .unknown,
            notes: string(input, "notes") ?? ""
        )
        await appState.addNetworkEntry(entry)
        let display = name.isEmpty ? company : name
        return ok(
            "Created network entry id=\(entry.id.uuidString) name=\(display)",
            summary: "Added to Network Hub: \(display)"
        )
    }

    private func updateNetworkEntry(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update network entry failed")
        }
        guard var entry = appState.networkEntries.first(where: { $0.id == id }) else {
            return err("No network entry with id \(id.uuidString).", summary: "Update network entry failed")
        }
        var changed = false
        if let v = string(input, "name").nonEmpty { entry.name = v; changed = true }
        if let v = string(input, "company").nonEmpty { entry.company = v; changed = true }
        if let v = string(input, "title") { entry.title = v; changed = true }
        if let v = parseNetworkType(string(input, "type")) { entry.type = v; changed = true }
        if let v = parseIndividualType(string(input, "individual_type")) { entry.individualType = v; changed = true }
        if let v = string(input, "industry") { entry.industry = v; changed = true }
        if let v = string(input, "location") { entry.location = v; changed = true }
        if let v = string(input, "email") { entry.email = v; changed = true }
        if let v = string(input, "linkedin") { entry.linkedin = v.nonEmpty; changed = true }
        if let v = parseCloseness(string(input, "closeness")) { entry.closeness = v; changed = true }
        if let v = string(input, "notes") { entry.notes = v; changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update network entry failed") }
        await appState.updateNetworkEntry(entry)
        let display = entry.name.isEmpty ? entry.company : entry.name
        return ok("Updated network entry \(entry.id.uuidString).", summary: "Updated network entry: \(display)")
    }

    private func createCompany(_ input: [String: Any]) async -> ToolResult {
        guard let name = string(input, "name").nonEmpty else {
            return err("Missing required 'name'.", summary: "Create company failed")
        }
        if let existing = appState.companies.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return err(
                "A company named '\(existing.name)' already exists (id \(existing.id.uuidString)). Use update_company to change it.",
                summary: "Company already exists"
            )
        }
        var linkedIds: [UUID] = []
        if let linked = linkedNetworkIds(input) {
            guard linked.unknown.isEmpty else {
                return err(
                    "Unknown network entry ids: \(linked.unknown.joined(separator: ", ")). Use search_items with type=network to find ids.",
                    summary: "Create company failed"
                )
            }
            linkedIds = linked.ids
        }
        let company = Company(
            name: name,
            type: parseCompanyType(string(input, "type")) ?? .unknown,
            location: string(input, "location") ?? "",
            isCustomer: input["is_customer"] as? Bool ?? false,
            commitmentAmount: double(input, "commitment_amount").flatMap { $0 > 0 ? $0 : nil },
            website: string(input, "website").nonEmpty,
            notes: string(input, "notes") ?? "",
            tags: stringArray(input, "tags"),
            linkedNetworkEntryIds: linkedIds
        )
        await appState.addCompany(company)
        return ok("Created company id=\(company.id.uuidString) name=\(name)", summary: "Created company: \(name)")
    }

    private func updateCompany(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update company failed")
        }
        guard var company = appState.companies.first(where: { $0.id == id }) else {
            return err("No company with id \(id.uuidString).", summary: "Update company failed")
        }
        var changed = false
        if let v = string(input, "name").nonEmpty { company.name = v; changed = true }
        if let v = parseCompanyType(string(input, "type")) { company.type = v; changed = true }
        if let v = string(input, "location") { company.location = v; changed = true }
        if let v = input["is_customer"] as? Bool { company.isCustomer = v; changed = true }
        if let v = double(input, "commitment_amount") { company.commitmentAmount = v > 0 ? v : nil; changed = true }
        if let v = string(input, "website") { company.website = v.nonEmpty; changed = true }
        if let v = string(input, "notes") { company.notes = v; changed = true }
        if input["tags"] != nil { company.tags = stringArray(input, "tags"); changed = true }
        if let linked = linkedNetworkIds(input) {
            guard linked.unknown.isEmpty else {
                return err(
                    "Unknown network entry ids: \(linked.unknown.joined(separator: ", ")). Use search_items with type=network to find ids.",
                    summary: "Update company failed"
                )
            }
            company.linkedNetworkEntryIds = linked.ids
            changed = true
        }
        guard changed else { return err("No fields provided to update.", summary: "Update company failed") }
        await appState.updateCompany(company)
        return ok("Updated company \(company.id.uuidString).", summary: "Updated company: \(company.name)")
    }

    private func createEvent(_ input: [String: Any]) async -> ToolResult {
        guard let name = string(input, "name").nonEmpty else {
            return err("Missing required 'name'.", summary: "Create event failed")
        }
        let event = Event(
            name: name,
            type: parseEventType(string(input, "type")) ?? .unknown,
            location: string(input, "location") ?? "",
            startDate: parseDate(string(input, "start_date")),
            endDate: parseDate(string(input, "end_date")),
            status: parseEventStatus(string(input, "status")) ?? .considering,
            budgetAmount: double(input, "budget_amount").flatMap { $0 > 0 ? $0 : nil },
            notes: string(input, "notes") ?? "",
            tags: stringArray(input, "tags")
        )
        await appState.addEvent(event)
        return ok("Created event id=\(event.id.uuidString) name=\(name)", summary: "Created event: \(name)")
    }

    private func updateEvent(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update event failed")
        }
        guard var event = appState.events.first(where: { $0.id == id }) else {
            return err("No event with id \(id.uuidString).", summary: "Update event failed")
        }
        var changed = false
        if let v = string(input, "name").nonEmpty { event.name = v; changed = true }
        if let v = parseEventType(string(input, "type")) { event.type = v; changed = true }
        if let v = string(input, "location") { event.location = v; changed = true }
        if input["start_date"] != nil {
            let raw = string(input, "start_date") ?? ""
            event.startDate = raw.isEmpty ? nil : parseDate(raw)
            changed = true
        }
        if input["end_date"] != nil {
            let raw = string(input, "end_date") ?? ""
            event.endDate = raw.isEmpty ? nil : parseDate(raw)
            changed = true
        }
        if let v = parseEventStatus(string(input, "status")) { event.status = v; changed = true }
        if let v = double(input, "budget_amount") { event.budgetAmount = v > 0 ? v : nil; changed = true }
        if let v = string(input, "notes") { event.notes = v; changed = true }
        if input["tags"] != nil { event.tags = stringArray(input, "tags"); changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update event failed") }
        await appState.updateEvent(event)
        return ok("Updated event \(event.id.uuidString).", summary: "Updated event: \(event.name)")
    }

    private func createCommunity(_ input: [String: Any]) async -> ToolResult {
        guard let name = string(input, "name").nonEmpty else {
            return err("Missing required 'name'.", summary: "Create community failed")
        }
        if let existing = appState.communities.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return err(
                "A community named '\(existing.name)' already exists (id \(existing.id.uuidString)). Use update_community to change it.",
                summary: "Community already exists"
            )
        }
        let community = Community(
            name: name,
            type: parseCommunityType(string(input, "type")) ?? .community,
            location: string(input, "location") ?? "",
            builderSupportPerk: input["builder_support_perk"] as? Bool ?? false,
            url: string(input, "url").nonEmpty,
            notes: string(input, "notes") ?? "",
            tags: stringArray(input, "tags")
        )
        await appState.addCommunity(community)
        return ok("Created community id=\(community.id.uuidString) name=\(name)", summary: "Created community: \(name)")
    }

    private func updateCommunity(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update community failed")
        }
        guard var community = appState.communities.first(where: { $0.id == id }) else {
            return err("No community with id \(id.uuidString).", summary: "Update community failed")
        }
        var changed = false
        if let v = string(input, "name").nonEmpty { community.name = v; changed = true }
        if let v = parseCommunityType(string(input, "type")) { community.type = v; changed = true }
        if let v = string(input, "location") { community.location = v; changed = true }
        if let v = input["builder_support_perk"] as? Bool { community.builderSupportPerk = v; changed = true }
        if let v = string(input, "url") { community.url = v.nonEmpty; changed = true }
        if let v = string(input, "notes") { community.notes = v; changed = true }
        if input["tags"] != nil { community.tags = stringArray(input, "tags"); changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update community failed") }
        await appState.updateCommunity(community)
        return ok("Updated community \(community.id.uuidString).", summary: "Updated community: \(community.name)")
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
        case "meeting":
            guard let m = appState.meetings.first(where: { $0.id == id }) else {
                return err("No meeting with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteMeeting(m)
            return ok("Deleted meeting \(id.uuidString).", summary: "Deleted meeting: \(m.title)")
        case "network":
            guard let n = appState.networkEntries.first(where: { $0.id == id }) else {
                return err("No network entry with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteNetworkEntry(n)
            let display = n.name.isEmpty ? n.company : n.name
            return ok("Deleted network entry \(id.uuidString).", summary: "Deleted network entry: \(display)")
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
        case "company":
            guard let c = appState.companies.first(where: { $0.id == id }) else {
                return err("No company with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteCompany(c)
            return ok("Deleted company \(id.uuidString).", summary: "Deleted company: \(c.name)")
        case "event":
            guard let e = appState.events.first(where: { $0.id == id }) else {
                return err("No event with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteEvent(e)
            return ok("Deleted event \(id.uuidString).", summary: "Deleted event: \(e.name)")
        case "community":
            guard let cm = appState.communities.first(where: { $0.id == id }) else {
                return err("No community with id \(id.uuidString).", summary: "Delete failed")
            }
            await appState.deleteCommunity(cm)
            return ok("Deleted community \(id.uuidString).", summary: "Deleted community: \(cm.name)")
        default:
            if let tab = appState.customTabs.first(where: { $0.slug == type }) {
                guard let record = appState.customRecords.first(where: { $0.id == id && $0.tabId == tab.id }) else {
                    return err("No \(tab.name) record with id \(id.uuidString).", summary: "Delete failed")
                }
                let title = record.displayTitle(in: tab)
                await appState.deleteCustomRecord(record)
                return ok("Deleted \(tab.name) record \(id.uuidString).", summary: "Deleted from \(tab.name): \(title)")
            }
            return err("Unsupported delete type: \(type).", summary: "Delete failed")
        }
    }

    // MARK: - Custom-tab records (generated create_<slug> / update_<slug> tools)

    private func createCustomTabRecord(tab: CustomTabDefinition, _ input: [String: Any]) async -> ToolResult {
        let values: [UUID: CustomFieldValue]
        do {
            values = try parseCustomFieldValues(tab: tab, input: input).compactMapValues { $0 }
        } catch let e as CustomFieldInputError {
            return err(e.message, summary: "Add to \(tab.name) failed")
        } catch {
            return err(error.localizedDescription, summary: "Add to \(tab.name) failed")
        }
        guard !values.isEmpty else {
            return err("Provide at least one field value. Columns: \(tab.fieldKeys().map { $0.key }.joined(separator: ", ")).",
                       summary: "Add to \(tab.name) failed")
        }
        let record = CustomRecord(tabId: tab.id, values: values)
        await appState.addCustomRecord(record)
        return ok("Created \(tab.name) record \(record.id.uuidString).",
                  summary: "Added to \(tab.name): \(record.displayTitle(in: tab))")
    }

    private func updateCustomTabRecord(tab: CustomTabDefinition, _ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "id")) else {
            return err("Missing or invalid 'id'.", summary: "Update \(tab.name) failed")
        }
        guard var record = appState.customRecords.first(where: { $0.id == id && $0.tabId == tab.id }) else {
            return err("No \(tab.name) record with id \(id.uuidString).", summary: "Update \(tab.name) failed")
        }
        let parsed: [UUID: CustomFieldValue?]
        do {
            parsed = try parseCustomFieldValues(tab: tab, input: input)
        } catch let e as CustomFieldInputError {
            return err(e.message, summary: "Update \(tab.name) failed")
        } catch {
            return err(error.localizedDescription, summary: "Update \(tab.name) failed")
        }
        guard !parsed.isEmpty else {
            return err("No fields provided to update.", summary: "Update \(tab.name) failed")
        }
        for (fieldId, value) in parsed {
            if let value, !value.isEmpty {
                record.values[fieldId] = value
            } else {
                record.values.removeValue(forKey: fieldId)
            }
        }
        await appState.updateCustomRecord(record)
        return ok("Updated \(tab.name) record \(record.id.uuidString).",
                  summary: "Updated \(tab.name): \(record.displayTitle(in: tab))")
    }

    /// Parse every provided field key in `input` against the tab's schema.
    /// nil values mean "explicitly cleared" (empty string / array / unchecked).
    private func parseCustomFieldValues(tab: CustomTabDefinition, input: [String: Any]) throws -> [UUID: CustomFieldValue?] {
        var out: [UUID: CustomFieldValue?] = [:]
        for (key, field) in tab.fieldKeys() {
            guard let raw = input[key], !(raw is NSNull) else { continue }
            out[field.id] = try CustomFieldValue.fromToolInput(raw, field: field)
        }
        return out
    }

    // MARK: - Tab management (create_tab / update_tab / get_tab / blocks / generic records)

    private struct TabToolError: Error {
        let message: String
    }

    private static let maxTabBlocks = 30
    private static let maxBatchRecords = 100

    /// Resolve the `tab` input param to a custom tab: exact slug first, then
    /// case-insensitive name, then slugified-name — with a corrective error
    /// listing what exists.
    private func requireTab(_ input: [String: Any]) throws -> CustomTabDefinition {
        guard let raw = string(input, "tab").nonEmpty else {
            throw TabToolError(message: "Missing 'tab'.\(availableTabsHint())")
        }
        let lowered = raw.lowercased()
        if let tab = appState.customTabs.first(where: { $0.slug == lowered }) { return tab }
        if let tab = appState.customTabs.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) { return tab }
        let slugged = CustomTabSlug.slugify(raw)
        if !slugged.isEmpty, let tab = appState.customTabs.first(where: { $0.slug == slugged }) { return tab }
        throw TabToolError(message: "No custom tab matching '\(raw)'.\(availableTabsHint())")
    }

    private func availableTabsHint() -> String {
        guard !appState.customTabs.isEmpty else {
            return " There are no custom tabs yet — create one with create_tab."
        }
        let list = appState.customTabs.map { "\($0.slug) (\"\($0.name)\")" }.joined(separator: ", ")
        return " Available tabs: \(list)."
    }

    /// Field by display name (case-insensitive) or slugified key.
    private func matchField(_ raw: String, in fields: [CustomFieldDefinition]) -> CustomFieldDefinition? {
        let needle = raw.trimmingCharacters(in: .whitespaces)
        if let f = fields.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame }) { return f }
        let key = CustomTabSlug.slugify(needle)
        guard !key.isEmpty else { return nil }
        return fields.first { CustomTabSlug.slugify($0.name) == key }
    }

    private func parseFieldKind(_ raw: String?, fieldName: String) throws -> CustomFieldKind {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .text }
        switch raw.replacingOccurrences(of: " ", with: "_") {
        case "text", "string": return .text
        case "long_text", "longtext": return .longText
        case "number", "integer", "float": return .number
        case "date", "datetime": return .date
        case "checkbox", "bool", "boolean": return .checkbox
        case "url", "link": return .url
        case "single_select", "singleselect", "select": return .singleSelect
        case "multi_select", "multiselect", "tags": return .multiSelect
        default:
            throw TabToolError(message: "Field '\(fieldName)': unknown kind '\(raw)'. Use one of: text, long_text, number, date, checkbox, url, single_select, multi_select.")
        }
    }

    private func parseOptionSpecs(_ raw: [Any], fieldName: String, startCount: Int = 0) throws -> [CustomFieldOption] {
        var out: [CustomFieldOption] = []
        for item in raw {
            var label: String
            var colorHex: String?
            if let s = item as? String {
                label = s.trimmingCharacters(in: .whitespaces)
            } else if let dict = item as? [String: Any],
                      let l = (dict["label"] as? String)?.trimmingCharacters(in: .whitespaces) {
                label = l
                colorHex = TabBlockColor.hex(for: dict["color"] as? String)
            } else {
                throw TabToolError(message: "Field '\(fieldName)': each option must be a string or {label, color}.")
            }
            guard !label.isEmpty else { continue }
            guard !out.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else { continue }
            let hex = colorHex ?? CustomFieldOptionPalette.hexes[(startCount + out.count) % CustomFieldOptionPalette.hexes.count]
            out.append(CustomFieldOption(label: label, colorHex: hex))
        }
        return out
    }

    /// Parse a create_tab / update_tab `fields` array into definitions.
    private func parseFieldSpecs(_ raw: Any?, startIndex: Int) throws -> [CustomFieldDefinition] {
        guard let arr = raw else { return [] }
        guard let items = arr as? [Any] else {
            throw TabToolError(message: "'fields' must be an array of {name, kind, options?} objects.")
        }
        var out: [CustomFieldDefinition] = []
        for (i, item) in items.enumerated() {
            guard let dict = item as? [String: Any],
                  let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                throw TabToolError(message: "fields[\(i)] needs a non-empty 'name'.")
            }
            let kind = try parseFieldKind(dict["kind"] as? String, fieldName: name)
            var options: [CustomFieldOption] = []
            if let rawOptions = dict["options"] as? [Any] {
                options = try parseOptionSpecs(rawOptions, fieldName: name)
            }
            if kind.usesOptions && options.isEmpty {
                throw TabToolError(message: "Field '\(name)' (\(kind.rawValue)) needs 'options' — an array of labels or {label, color}.")
            }
            out.append(CustomFieldDefinition(name: name, kind: kind, options: options, sortIndex: startIndex + out.count))
        }
        return out
    }

    /// Parse + validate a blocks array; ids are de-duplicated in order.
    private func parseBlocks(_ raw: Any?) throws -> [TabBlock] {
        guard let items = raw as? [Any] else {
            throw TabToolError(message: "'blocks' must be an array of block objects (see set_tab_blocks for the shapes).")
        }
        guard items.count <= Self.maxTabBlocks else {
            throw TabToolError(message: "Too many blocks (\(items.count)); maximum is \(Self.maxTabBlocks).")
        }
        var out: [TabBlock] = []
        for (i, item) in items.enumerated() {
            do {
                var block = try TabBlock.make(from: item, fallbackId: "block_\(i + 1)")
                if out.contains(where: { $0.id == block.id }) {
                    var n = 2
                    while out.contains(where: { $0.id == "\(block.id)_\(n)" }) { n += 1 }
                    block = TabBlock(id: "\(block.id)_\(n)", json: block.json)
                }
                out.append(block)
            } catch let e as TabBlockError {
                throw TabToolError(message: "blocks[\(i)]: \(e.message)")
            }
        }
        return out
    }

    /// SF Symbol names the model invents don't always exist — fall back to a
    /// generic table icon rather than a blank sidebar row.
    private func sanitizeIcon(_ raw: String?) -> String {
        guard let icon = raw.nonEmpty else { return "tablecells" }
        return NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil ? icon : "tablecells"
    }

    private func columnsDoc(_ tab: CustomTabDefinition) -> String {
        tab.fieldKeys().map { key, field in
            switch field.kind {
            case .singleSelect: return "\(key) (one of: \(field.options.map(\.label).joined(separator: "|")))"
            case .multiSelect: return "\(key) (any of: \(field.options.map(\.label).joined(separator: "|")))"
            default: return "\(key) (\(field.kind.rawValue))"
            }
        }.joined(separator: ", ")
    }

    private func createTab(_ input: [String: Any]) async -> ToolResult {
        guard let name = string(input, "name").nonEmpty else {
            return err("Missing 'name'.", summary: "Create tab failed")
        }
        if let existing = appState.customTabs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return err("A tab named \"\(name)\" already exists (slug \(existing.slug)). Use update_tab / add_tab_records / set_tab_blocks on it, or pick a different name.",
                       summary: "Create tab failed")
        }
        let layoutRaw = (string(input, "layout").nonEmpty ?? "table").lowercased()
        guard let layout = CustomTabLayout(rawValue: layoutRaw) else {
            return err("Unknown layout '\(layoutRaw)'. Use one of: \(CustomTabLayout.allCases.map(\.rawValue).joined(separator: ", ")).",
                       summary: "Create tab failed")
        }

        var fields: [CustomFieldDefinition]
        let blocks: [TabBlock]
        do {
            fields = try parseFieldSpecs(input["fields"], startIndex: 0)
            blocks = input["blocks"] != nil && !(input["blocks"] is NSNull) ? try parseBlocks(input["blocks"]) : []
        } catch let e as TabToolError {
            return err(e.message, summary: "Create tab failed")
        } catch {
            return err(error.localizedDescription, summary: "Create tab failed")
        }
        // A record-style tab with no columns would be unusable — seed a title
        // column. Dashboard tabs legitimately run field-less.
        if fields.isEmpty && layout != .dashboard {
            fields = [CustomFieldDefinition(name: "Name", kind: .text, sortIndex: 0)]
        }
        if layout == .board && !fields.contains(where: { $0.kind == .singleSelect }) {
            return err("layout=board needs a single_select field to group by — add one (e.g. Status with options like \"To do|In progress|Done\").",
                       summary: "Create tab failed")
        }
        var boardGroupFieldId: UUID?
        if let groupRaw = string(input, "board_group_by").nonEmpty {
            guard let field = matchField(groupRaw, in: fields), field.kind == .singleSelect else {
                return err("board_group_by '\(groupRaw)' must name one of the tab's single_select fields.",
                           summary: "Create tab failed")
            }
            boardGroupFieldId = field.id
        }

        let tab = await appState.addCustomTab(
            name: name,
            icon: sanitizeIcon(string(input, "icon")),
            fields: fields,
            layout: layout,
            subtitle: string(input, "subtitle").nonEmpty,
            boardGroupFieldId: boardGroupFieldId,
            blocks: blocks
        )

        var lines = ["Created tab \"\(name)\" — slug: \(tab.slug), layout: \(layout.rawValue)."]
        if !tab.fields.isEmpty {
            lines.append("Column keys: \(columnsDoc(tab)).")
            lines.append("Add rows NOW with add_tab_records(tab: \"\(tab.slug)\", records: [...]); edit with update_tab_record. (Dedicated create_\(tab.slug)/update_\(tab.slug) tools appear in your next session.)")
        }
        if layout == .dashboard {
            lines.append(blocks.isEmpty
                ? "It's a dashboard tab — compose it with set_tab_blocks(tab: \"\(tab.slug)\", blocks: [...])."
                : "Dashboard blocks: \(blocks.map(\.id).joined(separator: ", ")). Patch individual ones later with update_tab_block.")
        }
        lines.append("The tab is already visible in the user's sidebar.")
        return ok(lines.joined(separator: "\n"), summary: "Created tab: \(name)")
    }

    private func updateTab(_ input: [String: Any]) async -> ToolResult {
        var tab: CustomTabDefinition
        do {
            tab = try requireTab(input)
        } catch let e as TabToolError {
            return err(e.message, summary: "Update tab failed")
        } catch {
            return err(error.localizedDescription, summary: "Update tab failed")
        }

        var changes: [String] = []
        do {
            // Append new columns first so layout/board changes can reference them.
            if input["add_fields"] != nil && !(input["add_fields"] is NSNull) {
                let start = (tab.fields.map(\.sortIndex).max() ?? -1) + 1
                let added = try parseFieldSpecs(input["add_fields"], startIndex: start)
                for field in added {
                    guard matchField(field.name, in: tab.fields) == nil else {
                        throw TabToolError(message: "Field '\(field.name)' already exists on \(tab.slug).")
                    }
                    tab.fields.append(field)
                }
                if !added.isEmpty { changes.append("added column\(added.count == 1 ? "" : "s") \(added.map(\.name).joined(separator: ", "))") }
            }
            if let rawAddOptions = input["add_options"] as? [Any] {
                for item in rawAddOptions {
                    guard let dict = item as? [String: Any],
                          let fieldRaw = (dict["field"] as? String).nonEmpty,
                          let rawOptions = dict["options"] as? [Any] else {
                        throw TabToolError(message: "add_options entries must be {field, options:[...]}.")
                    }
                    guard let field = matchField(fieldRaw, in: tab.fields),
                          let fi = tab.fields.firstIndex(where: { $0.id == field.id }) else {
                        throw TabToolError(message: "add_options: no field '\(fieldRaw)' on \(tab.slug).")
                    }
                    guard field.kind.usesOptions else {
                        throw TabToolError(message: "add_options: field '\(field.name)' is \(field.kind.rawValue), not a select.")
                    }
                    let parsed = try parseOptionSpecs(rawOptions, fieldName: field.name, startCount: field.options.count)
                    let fresh = parsed.filter { option in
                        !tab.fields[fi].options.contains { $0.label.caseInsensitiveCompare(option.label) == .orderedSame }
                    }
                    tab.fields[fi].options.append(contentsOf: fresh)
                    if !fresh.isEmpty { changes.append("added \(field.name) option\(fresh.count == 1 ? "" : "s") \(fresh.map(\.label).joined(separator: ", "))") }
                }
            }
        } catch let e as TabToolError {
            return err(e.message, summary: "Update tab failed")
        } catch {
            return err(error.localizedDescription, summary: "Update tab failed")
        }

        if let newName = string(input, "name").nonEmpty, newName != tab.name {
            tab.name = newName
            changes.append("renamed to \"\(newName)\" (slug stays \(tab.slug))")
        }
        if let icon = string(input, "icon").nonEmpty {
            tab.icon = sanitizeIcon(icon)
            changes.append("icon → \(tab.icon)")
        }
        if let subtitle = string(input, "subtitle") {
            let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.subtitle = trimmed.isEmpty ? nil : trimmed
            changes.append(trimmed.isEmpty ? "cleared subtitle" : "subtitle updated")
        }
        if let layoutRaw = string(input, "layout").nonEmpty?.lowercased() {
            guard let layout = CustomTabLayout(rawValue: layoutRaw) else {
                return err("Unknown layout '\(layoutRaw)'. Use one of: \(CustomTabLayout.allCases.map(\.rawValue).joined(separator: ", ")).",
                           summary: "Update tab failed")
            }
            if layout == .board && !tab.fields.contains(where: { $0.kind == .singleSelect }) {
                return err("layout=board needs a single_select field to group by — add one via add_fields first.",
                           summary: "Update tab failed")
            }
            if layout != tab.layout {
                tab.layout = layout
                changes.append("layout → \(layout.rawValue)")
            }
        }
        if let groupRaw = string(input, "board_group_by").nonEmpty {
            guard let field = matchField(groupRaw, in: tab.fields), field.kind == .singleSelect else {
                return err("board_group_by '\(groupRaw)' must name one of the tab's single_select fields.",
                           summary: "Update tab failed")
            }
            tab.boardGroupFieldId = field.id
            changes.append("board groups by \(field.name)")
        }

        guard !changes.isEmpty else {
            return err("Nothing to change — pass at least one of name, icon, subtitle, layout, board_group_by, add_fields, add_options.",
                       summary: "Update tab failed")
        }
        await appState.updateCustomTab(tab)
        var lines = ["Updated tab \(tab.slug): \(changes.joined(separator: "; "))."]
        if !tab.fields.isEmpty { lines.append("Column keys now: \(columnsDoc(tab)).") }
        return ok(lines.joined(separator: "\n"), summary: "Updated tab: \(tab.name)")
    }

    private func getTab(_ input: [String: Any]) -> ToolResult {
        // No tab → compact list of every custom tab.
        guard string(input, "tab").nonEmpty != nil else {
            guard !appState.customTabs.isEmpty else {
                return ok("No custom tabs yet. Create one with create_tab.", summary: "No custom tabs")
            }
            let lines = appState.customTabs.map { tab -> String in
                let count = appState.customRecords.filter { $0.tabId == tab.id }.count
                var line = "- \(tab.slug) (\"\(tab.name)\") — layout \(tab.layout.rawValue), \(count) record\(count == 1 ? "" : "s")"
                if !tab.fields.isEmpty { line += ", columns: \(tab.fieldKeys().map(\.key).joined(separator: ", "))" }
                if !tab.blocks.isEmpty { line += ", blocks: \(tab.blocks.map(\.id).joined(separator: ", "))" }
                return line
            }
            return ok(lines.joined(separator: "\n"), summary: "Listed \(appState.customTabs.count) custom tabs")
        }

        let tab: CustomTabDefinition
        do {
            tab = try requireTab(input)
        } catch let e as TabToolError {
            return err(e.message, summary: "Get tab failed")
        } catch {
            return err(error.localizedDescription, summary: "Get tab failed")
        }

        var dict: [String: Any] = [
            "name": tab.name,
            "slug": tab.slug,
            "icon": tab.icon,
            "layout": tab.layout.rawValue,
            "record_count": appState.customRecords.filter { $0.tabId == tab.id }.count,
            "fields": tab.fieldKeys().map { key, field -> [String: Any] in
                var f: [String: Any] = ["key": key, "name": field.name, "kind": field.kind.rawValue]
                if field.kind.usesOptions { f["options"] = field.options.map(\.label) }
                return f
            },
            "blocks": tab.blocks.map { $0.json.anyValue }
        ]
        if let subtitle = tab.subtitle { dict["subtitle"] = subtitle }
        if let group = tab.boardGroupField { dict["board_group_by"] = group.name }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return err("Failed to serialize tab definition.", summary: "Get tab failed")
        }
        return ok(json, summary: "Read tab: \(tab.name)")
    }

    private func setTabBlocks(_ input: [String: Any]) async -> ToolResult {
        let tab: CustomTabDefinition
        let blocks: [TabBlock]
        do {
            tab = try requireTab(input)
            blocks = try parseBlocks(input["blocks"])
        } catch let e as TabToolError {
            return err(e.message, summary: "Set blocks failed")
        } catch {
            return err(error.localizedDescription, summary: "Set blocks failed")
        }
        await appState.setCustomTabBlocks(tabId: tab.id, blocks: blocks)
        var lines = ["Set \(blocks.count) block\(blocks.count == 1 ? "" : "s") on \(tab.slug): \(blocks.map(\.id).joined(separator: ", "))."]
        if tab.layout != .dashboard {
            lines.append("NOTE: this tab's layout is '\(tab.layout.rawValue)', so blocks aren't visible — call update_tab(tab: \"\(tab.slug)\", layout: \"dashboard\") to show them (embed the rows with a {\"type\":\"records\"} block).")
        }
        return ok(lines.joined(separator: "\n"), summary: "Rebuilt \(tab.name) dashboard")
    }

    private func updateTabBlock(_ input: [String: Any]) async -> ToolResult {
        let tab: CustomTabDefinition
        do {
            tab = try requireTab(input)
        } catch let e as TabToolError {
            return err(e.message, summary: "Update block failed")
        } catch {
            return err(error.localizedDescription, summary: "Update block failed")
        }
        guard let blockDict = input["block"] as? [String: Any] else {
            return err("Missing 'block' — the full block object including its \"id\" and \"type\".", summary: "Update block failed")
        }

        if (input["remove"] as? Bool) == true {
            let id = ((blockDict["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else {
                return err("remove=true needs block.id.", summary: "Update block failed")
            }
            guard tab.blocks.contains(where: { $0.id == id }) else {
                return err("No block '\(id)' on \(tab.slug). Current blocks: \(tab.blocks.map(\.id).joined(separator: ", ")).",
                           summary: "Update block failed")
            }
            await appState.removeCustomTabBlock(tabId: tab.id, blockId: id)
            return ok("Removed block '\(id)' from \(tab.slug).", summary: "Removed \(tab.name) block")
        }

        let block: TabBlock
        do {
            block = try TabBlock.make(from: blockDict, fallbackId: "block_\(tab.blocks.count + 1)")
        } catch let e as TabBlockError {
            return err(e.message, summary: "Update block failed")
        } catch {
            return err(error.localizedDescription, summary: "Update block failed")
        }
        let existed = tab.blocks.contains { $0.id == block.id }
        if !existed && tab.blocks.count >= Self.maxTabBlocks {
            return err("Tab already has \(tab.blocks.count) blocks (max \(Self.maxTabBlocks)) — remove or replace one instead.",
                       summary: "Update block failed")
        }
        await appState.upsertCustomTabBlock(tabId: tab.id, block: block)
        var lines = ["\(existed ? "Updated" : "Added") block '\(block.id)' on \(tab.slug)."]
        if tab.layout != .dashboard {
            lines.append("NOTE: layout is '\(tab.layout.rawValue)' — blocks render when layout=dashboard.")
        }
        return ok(lines.joined(separator: "\n"),
                  summary: "\(existed ? "Updated" : "Added") \(tab.name) block: \(block.id)")
    }

    private func addTabRecords(_ input: [String: Any]) async -> ToolResult {
        let tab: CustomTabDefinition
        do {
            tab = try requireTab(input)
        } catch let e as TabToolError {
            return err(e.message, summary: "Add rows failed")
        } catch {
            return err(error.localizedDescription, summary: "Add rows failed")
        }
        guard !tab.fields.isEmpty else {
            return err("Tab \(tab.slug) has no columns — add some with update_tab(add_fields:) first.", summary: "Add rows failed")
        }
        guard let rawRecords = input["records"] as? [Any], !rawRecords.isEmpty else {
            return err("Missing 'records' — an array of row objects keyed by column key. Columns: \(columnsDoc(tab)).",
                       summary: "Add rows failed")
        }
        guard rawRecords.count <= Self.maxBatchRecords else {
            return err("Too many records (\(rawRecords.count)); maximum is \(Self.maxBatchRecords) per call.", summary: "Add rows failed")
        }

        // Validate everything before creating anything, so a partial batch
        // never lands and the agent can retry the whole call safely.
        var parsed: [[UUID: CustomFieldValue]] = []
        var problems: [String] = []
        for (i, raw) in rawRecords.enumerated() {
            guard let dict = raw as? [String: Any] else {
                problems.append("records[\(i)]: not an object.")
                continue
            }
            do {
                let values = try parseCustomFieldValues(tab: tab, input: dict).compactMapValues { $0 }
                if values.isEmpty {
                    problems.append("records[\(i)]: no recognized column keys. Columns: \(tab.fieldKeys().map(\.key).joined(separator: ", ")).")
                } else {
                    parsed.append(values)
                }
            } catch let e as CustomFieldInputError {
                problems.append("records[\(i)]: \(e.message)")
            } catch {
                problems.append("records[\(i)]: \(error.localizedDescription)")
            }
        }
        guard problems.isEmpty else {
            return err("No rows added — fix these and resend the whole batch:\n" + problems.joined(separator: "\n"),
                       summary: "Add rows failed")
        }

        let records = parsed.map { CustomRecord(tabId: tab.id, values: $0) }
        await appState.addCustomRecords(records)
        let lines = records.map { "- \($0.displayTitle(in: tab)) — id \($0.id.uuidString)" }
        return ok("Added \(records.count) row\(records.count == 1 ? "" : "s") to \(tab.slug):\n" + lines.joined(separator: "\n"),
                  summary: "Added \(records.count) row\(records.count == 1 ? "" : "s") to \(tab.name)")
    }

    private func updateTabRecordGeneric(_ input: [String: Any]) async -> ToolResult {
        let tab: CustomTabDefinition
        do {
            tab = try requireTab(input)
        } catch let e as TabToolError {
            return err(e.message, summary: "Update row failed")
        } catch {
            return err(error.localizedDescription, summary: "Update row failed")
        }
        guard let values = input["values"] as? [String: Any], !values.isEmpty else {
            return err("Missing 'values' — an object of column key → new value. Columns: \(columnsDoc(tab)).",
                       summary: "Update row failed")
        }
        // Reuse the per-tab update path: values + id in one flat input.
        var flat: [String: Any] = values
        flat["id"] = input["id"]
        return await updateCustomTabRecord(tab: tab, flat)
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
            var defaults: Set<String> = ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "network", "company", "event", "community", "file", "x_post", "x_follower", "x_dm"]
            defaults.formUnion(appState.customTabs.map(\.slug))
            return defaults
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
        if types.contains("network") {
            // Matches across the full entry incl. the structured LinkedIn profile
            // (summary, every experience, education, skills, languages, certs).
            for n in appState.networkEntries where textMatches([n.searchableContent]) {
                matches.append(.init(id: n.id, type: "network",
                                     title: n.name.isEmpty ? n.company : n.name,
                                     snippet: n.displayInfo,
                                     date: n.updatedAt, dueDate: nil))
            }
        }
        if types.contains("company") {
            for c in appState.companies where textMatches([c.searchableContent]) {
                let snippet = [c.type.label, c.location, c.isCustomer ? "Customer" : "", c.formattedCommitment ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                matches.append(.init(id: c.id, type: "company", title: c.name,
                                     snippet: snippet, date: c.updatedAt, dueDate: nil))
            }
        }
        if types.contains("event") {
            for e in appState.events where textMatches([e.searchableContent]) {
                let snippet = [e.type.label, e.location, e.status.label, e.dateRangeText]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                matches.append(.init(id: e.id, type: "event", title: e.name,
                                     snippet: snippet, date: e.updatedAt, dueDate: e.startDate))
            }
        }
        if types.contains("community") {
            for cm in appState.communities where textMatches([cm.searchableContent]) {
                let snippet = [cm.type.label, cm.location, cm.builderSupportPerk ? "Builder perk" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                matches.append(.init(id: cm.id, type: "community", title: cm.name,
                                     snippet: snippet, date: cm.updatedAt, dueDate: nil))
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
        for tab in appState.customTabs where types.contains(tab.slug) {
            for r in appState.customRecords where r.tabId == tab.id {
                if !textMatches([r.searchableText(in: tab)]) { continue }
                // Snippet: the non-title columns as "Name: value" pairs.
                let snippet = tab.sortedFields.dropFirst()
                    .compactMap { f in r.values[f.id].map { "\(f.name): \($0.displayString(for: f))" } }
                    .joined(separator: " · ")
                matches.append(.init(id: r.id, type: tab.slug, title: r.displayTitle(in: tab),
                                     snippet: String(snippet.prefix(140)),
                                     date: r.updatedAt, dueDate: nil))
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
        case "network":
            if let n = appState.networkEntries.first(where: { $0.id == id }) {
                var out: [String: Any] = [
                    "id": n.id.uuidString, "type": "network",
                    "name": n.name,
                    "entry_type": n.type.label,
                    "role": n.individualType.label,
                    "company": n.company,
                    "industry": n.industry,
                    "title": n.title,
                    "location": n.location,
                    "email": n.email,
                    "closeness": n.closeness.label,
                    "linkedin": n.linkedin ?? "",
                    "notes": n.notes
                ]
                if let p = n.profile {
                    out["headline"] = p.headline
                    out["summary"] = p.summary
                    out["skills"] = p.skills
                    out["languages"] = p.languages
                    out["certifications"] = p.certifications
                    out["experience"] = p.experiences.map {
                        ["company": $0.company, "title": $0.title, "dates": $0.dateRange,
                         "location": $0.location, "description": $0.description]
                    }
                    out["education"] = p.education.map {
                        ["school": $0.school, "detail": $0.detail]
                    }
                }
                payload = out
            }
        case "company":
            if let c = appState.companies.first(where: { $0.id == id }) {
                payload = [
                    "id": c.id.uuidString, "type": "company",
                    "name": c.name,
                    "company_type": c.type.label,
                    "location": c.location,
                    "is_customer": c.isCustomer,
                    "commitment_amount": c.commitmentAmount ?? NSNull(),
                    "website": c.website ?? "",
                    "tags": c.tags,
                    "notes": c.notes,
                    "linked_people": c.linkedNetworkEntryIds.compactMap { lid in
                        appState.networkEntries.first(where: { $0.id == lid }).map {
                            ["id": $0.id.uuidString, "name": $0.name, "role": $0.displayInfo]
                        }
                    },
                    "updated_at": df.string(from: c.updatedAt)
                ]
            }
        case "event":
            if let e = appState.events.first(where: { $0.id == id }) {
                payload = [
                    "id": e.id.uuidString, "type": "event",
                    "name": e.name,
                    "event_type": e.type.label,
                    "location": e.location,
                    "status": e.status.label,
                    "start_date": e.startDate.map { df.string(from: $0) } ?? NSNull(),
                    "end_date": e.endDate.map { df.string(from: $0) } ?? NSNull(),
                    "budget_amount": e.budgetAmount ?? NSNull(),
                    "tags": e.tags,
                    "notes": e.notes,
                    "updated_at": df.string(from: e.updatedAt)
                ]
            }
        case "community":
            if let cm = appState.communities.first(where: { $0.id == id }) {
                payload = [
                    "id": cm.id.uuidString, "type": "community",
                    "name": cm.name,
                    "community_type": cm.type.label,
                    "location": cm.location,
                    "builder_support_perk": cm.builderSupportPerk,
                    "url": cm.url ?? "",
                    "tags": cm.tags,
                    "notes": cm.notes,
                    "updated_at": df.string(from: cm.updatedAt)
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
            guard let tab = appState.customTabs.first(where: { $0.slug == type }) else {
                return err("Unsupported type: \(type).", summary: "Fetch failed")
            }
            if let r = appState.customRecords.first(where: { $0.id == id && $0.tabId == tab.id }) {
                var out: [String: Any] = [
                    "id": r.id.uuidString, "type": tab.slug,
                    "title": r.displayTitle(in: tab),
                    "created_at": df.string(from: r.createdAt),
                    "updated_at": df.string(from: r.updatedAt)
                ]
                for (key, field) in tab.fieldKeys() {
                    out[key] = r.values[field.id].map { $0.toolOutputValue(for: field) } ?? NSNull()
                }
                payload = out
            }
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
        guard var file = appState.files.first(where: { $0.id == id }) else {
            return err("No file with id \(id.uuidString). Use `search_items` with type=\"file\" to discover ids.",
                       summary: "File not found")
        }
        let maxChars: Int = {
            let raw = (input["max_chars"] as? Int) ?? (Int(string(input, "max_chars") ?? "") ?? 20_000)
            return min(max(raw, 1), 200_000)
        }()

        let fileURL = await FileStorageService.shared.getFileURL(for: file)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)

        // Lazy backfill: spreadsheets imported before native xlsx extraction
        // existed carry no stored text — extract now and persist so this and
        // every future read (and search) sees the cells.
        if file.fileType == .excel, (file.extractedText ?? "").isEmpty, exists,
           let text = XLSXReader.csvText(from: fileURL) {
            file.extractedText = text
            await appState.updateFile(file)
        }
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
            hint = "Spreadsheet cells extracted as CSV text above (multi-sheet workbooks get a '# Sheet:' header per sheet; date cells show as raw serial numbers). Legacy .xls files can't be extracted — for those, ask the user to re-export as .xlsx or CSV."
        case .pdf:
            hint = "PDF text shown above. For layout-sensitive content, call the built-in `Read` tool with the absolute path."
        case .csv, .text:
            hint = "Full text above. Use the built-in `Grep` tool on the path for large files."
        case .video:
            hint = "Video file (no text extraction). Reference by path or hand the user a click-through preview via `attach_item_preview` with type=`file`."
        case .audio:
            hint = "Audio file (no text extraction). Reference by path or hand the user a click-through preview via `attach_item_preview` with type=`file`."
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

    // MARK: - Create file (downloadable deliverables)

    /// Extensions written verbatim from the `content` string. Everything here
    /// must also be importable by `FileType.from(extension:)`.
    private static let createFileTextExtensions: Set<String> = [
        "csv", "txt", "md", "markdown", "json", "yaml", "yml", "html", "xml", "log"
    ]

    /// Keeps a runaway agent from staging something enormous through the
    /// chat pipeline — 20 MB covers any plausible deliverable.
    private static let createFileMaxBytes = 20 * 1024 * 1024

    /// Build a real file from the agent's spec (text passthrough, xlsx from
    /// rows, pdf from markdown), import it into Otto's Files tab, and return
    /// a result line the chat layer parses to auto-attach a downloadable
    /// file card (see `OttoTools.parseCreatedFileResult`).
    private func createFile(_ input: [String: Any]) async -> ToolResult {
        guard let rawName = string(input, "filename")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return err("Missing required 'filename' (including extension, e.g. report.xlsx).",
                       summary: "Create file failed")
        }
        // Strip any path components and characters macOS filenames can't hold.
        let filename = (rawName as NSString).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "_")
        let ext = (filename as NSString).pathExtension.lowercased()
        let supported = Self.createFileTextExtensions.sorted().joined(separator: ", ")
        guard !ext.isEmpty else {
            return err("'filename' needs an extension. Supported: \(supported), xlsx, pdf.",
                       summary: "Create file failed")
        }

        let data: Data
        switch ext {
        case _ where Self.createFileTextExtensions.contains(ext):
            guard let content = string(input, "content"), !content.isEmpty else {
                return err("A .\(ext) file needs its text in 'content'.", summary: "Create file failed")
            }
            data = Data(content.utf8)
        case "xlsx":
            // Preferred shape: `sheets` — one tab per logical section.
            // `rows` (+ optional `sheet_name`) stays as single-sheet shorthand.
            var sheets: [(name: String, rows: [[Any]])] = []
            if let rawSheets = input["sheets"] as? [[String: Any]], !rawSheets.isEmpty {
                for (i, raw) in rawSheets.enumerated() {
                    guard let rows = raw["rows"] as? [[Any]], !rows.isEmpty else {
                        return err("Sheet \(i + 1) needs a non-empty 'rows' array of arrays of cell values.",
                                   summary: "Create file failed")
                    }
                    let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    sheets.append((name.isEmpty ? "Sheet\(i + 1)" : name, rows))
                }
            } else if let rows = input["rows"] as? [[Any]], !rows.isEmpty {
                sheets = [(string(input, "sheet_name") ?? "Sheet1", rows)]
            } else {
                return err("A .xlsx file needs 'sheets' (array of {name, rows}) or 'rows' (array of arrays of cell values, e.g. rows=[[\"Name\",\"Amount\"],[\"Acme\",1200]]).",
                           summary: "Create file failed")
            }
            do {
                data = try AgentFileCreation.xlsxData(sheets: sheets)
            } catch {
                return err("xlsx build failed: \(error.localizedDescription)", summary: "Create file failed")
            }
        case "pdf":
            guard let content = string(input, "content"), !content.isEmpty else {
                return err("A .pdf file needs its body text in 'content' (markdown-ish: # headings, - bullets, **bold**).",
                           summary: "Create file failed")
            }
            do {
                data = try AgentFileCreation.pdfData(markdown: content)
            } catch {
                return err("PDF rendering failed: \(error.localizedDescription)", summary: "Create file failed")
            }
        default:
            return err("Unsupported extension '.\(ext)'. Supported: \(supported), xlsx, pdf.",
                       summary: "Create file failed")
        }

        guard data.count <= Self.createFileMaxBytes else {
            return err("File would be \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) — the limit is 20 MB. Produce something smaller.",
                       summary: "Create file failed")
        }

        // Stage under the exact filename (import derives name + type from the
        // URL), then hand it to the shared Files pipeline.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-createfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try data.write(to: staged)
        } catch {
            return err("Couldn't stage the file: \(error.localizedDescription)", summary: "Create file failed")
        }

        do {
            var file = try await appState.importFile(from: staged)
            let notes = string(input, "notes") ?? ""
            file.notes = notes.isEmpty ? "Created by Otto in chat" : notes
            file.tags = ["agent-created"]
            await appState.updateFile(file)
            return ok(
                """
                Created file: \(file.id.uuidString) — \(filename) (\(file.formattedSize))
                Saved to Otto's Files tab. A downloadable file card was attached to your reply automatically — do NOT call attach_item_preview for this file, and don't repeat its full contents in prose. You can reference it inline as [\(filename)](otto://file/\(file.id.uuidString)).
                """,
                summary: "Created \(filename) (\(file.formattedSize))"
            )
        } catch {
            return err("Import failed: \(error.localizedDescription)", summary: "Create file failed")
        }
    }

    // MARK: - GenMedia (fal.ai)

    /// `genmedia models <query> --json` → JSON list of matching fal models.
    /// The agent uses this to discover the right model before inspecting its
    /// schema and calling `genmedia_run`.
    private func genmediaSearchModels(_ input: [String: Any]) async -> ToolResult {
        let query = string(input, "query") ?? ""
        let category = string(input, "category")
        let limit = max(1, min((input["limit"] as? Int) ?? 10, 50))
        do {
            let data = try await GenMediaService.shared.searchModels(
                query: query,
                category: category,
                limit: limit
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return ok(text, summary: "Searched fal models for '\(query.isEmpty ? "*" : query)'")
        } catch let e as GenMediaService.GenMediaError {
            return err(e.errorDescription ?? "genmedia failed", summary: "Model search failed")
        } catch {
            return err(error.localizedDescription, summary: "Model search failed")
        }
    }

    /// `genmedia schema <model> --json` → JSON schema for the model's inputs.
    /// Should be called before `genmedia_run` so the agent knows the field
    /// shape it has to fill.
    private func genmediaGetModelSchema(_ input: [String: Any]) async -> ToolResult {
        guard let modelId = string(input, "model_id")?.trimmingCharacters(in: .whitespaces),
              !modelId.isEmpty else {
            return err("Missing 'model_id'.", summary: "Schema fetch failed")
        }
        do {
            let data = try await GenMediaService.shared.modelSchema(modelId: modelId)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return ok(text, summary: "Schema for \(modelId)")
        } catch let e as GenMediaService.GenMediaError {
            return err(e.errorDescription ?? "genmedia failed", summary: "Schema fetch failed")
        } catch {
            return err(error.localizedDescription, summary: "Schema fetch failed")
        }
    }

    /// `genmedia run <model> …` → spawns the CLI, lets the model generate,
    /// then imports every produced file into Otto's Files tab and returns
    /// the new file ids so the agent can attach previews. Each File's notes
    /// get the prompt + request id, and its tags include "genmedia" plus a
    /// slug of the model id so they're filterable in the Files UI later.
    private func genmediaRun(_ input: [String: Any]) async -> ToolResult {
        guard let modelId = string(input, "model_id")?.trimmingCharacters(in: .whitespaces),
              !modelId.isEmpty else {
            return err("Missing 'model_id'.", summary: "Generation failed")
        }
        guard let inputs = input["inputs"] as? [String: Any] else {
            return err("Missing 'inputs' object.", summary: "Generation failed")
        }
        let promptSummary = string(input, "prompt_summary") ?? (inputs["prompt"] as? String ?? "")

        // Per-call scratch dir; genmedia downloads land here, we then move
        // each resulting file into Otto's Files via FileStorageService.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-genmedia-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let runResult: GenMediaService.RunResult
        do {
            runResult = try await GenMediaService.shared.runModel(
                modelId: modelId,
                inputs: inputs,
                downloadDir: scratch
            )
        } catch let e as GenMediaService.GenMediaError {
            return err(e.errorDescription ?? "genmedia failed", summary: "Generation failed")
        } catch {
            return err(error.localizedDescription, summary: "Generation failed")
        }

        guard !runResult.downloadedFiles.isEmpty else {
            // The model returned without writing files — surface the raw JSON
            // so the agent can decide what to tell the user (it might include
            // text-only output, or an error code we don't recognise).
            let raw = String(data: runResult.rawOutput, encoding: .utf8) ?? "{}"
            return ok(raw, summary: "Model returned no media")
        }

        // Import each output into Otto's Files, then patch in genmedia
        // metadata as notes/tags. Failures on individual files are
        // collected and reported but don't abort the batch.
        let modelSlug = modelId.replacingOccurrences(of: "/", with: "-")
        var imported: [[String: Any]] = []
        var failures: [String] = []
        for url in runResult.downloadedFiles {
            do {
                var file = try await appState.importFile(from: url)
                let parts: [String] = [
                    promptSummary.isEmpty ? "" : "Prompt: \(promptSummary)",
                    "Model: \(modelId)",
                    runResult.requestId.map { "Request: \($0)" } ?? ""
                ].filter { !$0.isEmpty }
                file.notes = parts.joined(separator: "\n")
                file.tags = ["genmedia", modelSlug]
                await appState.updateFile(file)
                imported.append([
                    "file_id": file.id.uuidString,
                    "file_type": file.fileType.rawValue,
                    "extension": file.fileExtension,
                    "name": file.name
                ])
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let payload: [String: Any] = [
            "model_id": modelId,
            "request_id": runResult.requestId ?? "",
            "files": imported,
            "import_failures": failures
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let countLabel = imported.count == 1 ? "1 file" : "\(imported.count) files"
        return ok(text, summary: "Generated \(countLabel) with \(modelId)")
    }

    /// `genmedia upload <path> --json` → CDN URL for an existing Otto File.
    /// Used for image-to-image / video-to-video flows where the agent
    /// wants to feed a user-imported file into another model.
    private func genmediaUploadFile(_ input: [String: Any]) async -> ToolResult {
        guard let id = parseUUID(string(input, "file_id")) else {
            return err("Missing or invalid 'file_id'.", summary: "Upload failed")
        }
        guard let file = appState.files.first(where: { $0.id == id }) else {
            return err("No file with id \(id.uuidString). Use `search_items` with type=file first.",
                       summary: "Upload failed")
        }
        let url = await FileStorageService.shared.getFileURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return err("File binary missing on disk for \(file.name).", summary: "Upload failed")
        }
        do {
            let cdnURL = try await GenMediaService.shared.uploadFile(at: url)
            let payload: [String: Any] = [
                "file_id": file.id.uuidString,
                "name": file.name,
                "url": cdnURL
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return ok(text, summary: "Uploaded \(file.name) to fal CDN")
        } catch let e as GenMediaService.GenMediaError {
            return err(e.errorDescription ?? "genmedia failed", summary: "Upload failed")
        } catch {
            return err(error.localizedDescription, summary: "Upload failed")
        }
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

    private func updateHabitTool(_ input: [String: Any]) async -> ToolResult {
        guard let raw = string(input, "habit")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return err("Missing required 'habit' (id or name).", summary: "Update habit failed")
        }
        guard var habit = resolveHabit(raw) else {
            return err(
                "No habit matches '\(raw)'. Active habits: \(habitNames()).",
                summary: "Update habit failed"
            )
        }
        var changed = false
        if let t = string(input, "title").nonEmpty { habit.title = t; changed = true }
        if let n = string(input, "notes") { habit.notes = n; changed = true }
        if let k = parseHabitKind(string(input, "kind")) { habit.kind = k; changed = true }
        if let u = string(input, "unit") { habit.unit = u.nonEmpty; changed = true }
        if let target = double(input, "daily_target") { habit.dailyTarget = max(0, target); changed = true }
        if string(input, "frequency").nonEmpty != nil { habit.frequency = parseFrequency(input); changed = true }
        if let c = parseHabitCategory(string(input, "category")) { habit.category = c; changed = true }
        if let icon = string(input, "icon").nonEmpty { habit.iconName = icon; changed = true }
        if let color = parseColorTag(string(input, "color")) { habit.colorTag = color; changed = true }
        if let archived = input["archived"] as? Bool { habit.isArchived = archived; changed = true }
        guard changed else { return err("No fields provided to update.", summary: "Update habit failed") }
        await appState.updateHabit(habit)
        return ok("Updated habit \(habit.id.uuidString).", summary: "Updated habit: \(habit.title)")
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

    private func double(_ input: [String: Any], _ key: String) -> Double? {
        if let n = input[key] as? Double { return n }
        if let n = input[key] as? Int { return Double(n) }
        if let s = string(input, key), let n = Double(s) { return n }
        return nil
    }

    private func intValue(_ input: [String: Any], _ key: String) -> Int? {
        if let n = input[key] as? Int { return n }
        if let n = input[key] as? Double { return Int(n) }
        if let s = string(input, key), let n = Int(s) { return n }
        return nil
    }

    /// Resolve `linked_network_entry_ids` input into known NetworkEntry ids.
    /// Returns nil when the key is absent; unknown/invalid ids are reported
    /// back to the agent rather than silently dropped.
    private func linkedNetworkIds(_ input: [String: Any]) -> (ids: [UUID], unknown: [String])? {
        guard input["linked_network_entry_ids"] != nil else { return nil }
        var ids: [UUID] = []
        var unknown: [String] = []
        for raw in stringArray(input, "linked_network_entry_ids") {
            if let id = UUID(uuidString: raw), appState.networkEntries.contains(where: { $0.id == id }) {
                ids.append(id)
            } else {
                unknown.append(raw)
            }
        }
        return (ids, unknown)
    }

    // MARK: - CRM enum parsing
    //
    // The tool schemas advertise snake_case values ("app_studio",
    // "close_friend") while the Swift enums use display-style raw values
    // ("App Studio", "Close friend"). Folding both sides to bare
    // alphanumerics makes the match format-insensitive.

    private func foldEnumKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func parseNetworkType(_ s: String?) -> NetworkType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return NetworkType.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseIndividualType(_ s: String?) -> IndividualType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return IndividualType.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseCloseness(_ s: String?) -> NetworkCloseness? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        // Accept both the schema's "intro_path_available" and a bare "intro_path".
        if key == "intropath" { return .introPath }
        return NetworkCloseness.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseCompanyType(_ s: String?) -> CompanyType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return CompanyType.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseEventType(_ s: String?) -> EventType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return EventType.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseEventStatus(_ s: String?) -> EventStatus? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return EventStatus.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseCommunityType(_ s: String?) -> CommunityType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return CommunityType.allCases.first { foldEnumKey($0.rawValue) == key }
    }

    private func parseMediaType(_ s: String?) -> Bookmark.MediaType? {
        guard let s = s.nonEmpty else { return nil }
        let key = foldEnumKey(s)
        return Bookmark.MediaType.allCases.first { foldEnumKey($0.rawValue) == key }
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
