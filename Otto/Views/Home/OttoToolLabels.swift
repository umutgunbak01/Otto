import Foundation

/// Friendly chat-step descriptions for `OttoTools` calls.
///
/// Produces a two-part label — `verb` (always present) and `arg` (the most
/// useful single field from the tool's input, if any) — that the chat view
/// renders as the call line of a `ToolStepRow`.
enum OttoToolLabels {

    struct Label {
        let verb: String
        let arg: String?
    }

    private static let argMaxChars = 50

    /// Live entry point. `input` is the JSON object Claude sent for this tool
    /// call; `appState` is used to resolve item ids to titles. `name` may be
    /// MCP-prefixed (`mcp__otto__search_items` over the Hermes backend) — it
    /// is canonicalized before matching.
    @MainActor
    static func describe(name rawName: String, input: [String: Any], appState: AppState?) -> Label {
        let name = OttoTools.canonicalToolName(rawName)
        // Genmedia tools can arrive under backend-specific naming the switch
        // below can't see (Hermes humanizes MCP titles: "Mcp Otto Genmedia
        // Run") — suffix-match the normalized name like OttoTools does.
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "_")
        if normalized.hasSuffix("genmedia_search_models") {
            return Label(verb: "Searching fal models:", arg: quoted(string(input, "query")))
        }
        if normalized.hasSuffix("genmedia_get_model_schema") {
            return Label(verb: "Fetching model schema:", arg: trim(string(input, "model_id")))
        }
        if normalized.hasSuffix("genmedia_run") {
            return Label(verb: "Generating media:", arg: trim(string(input, "model_id")))
        }
        if normalized.hasSuffix("genmedia_upload_file") {
            return Label(verb: "Uploading to fal:", arg: resolveFileName(input: input, appState: appState))
        }
        switch name {
        case "search_items":
            return Label(verb: "Searching for", arg: quoted(string(input, "query")))
        case "grep_data":
            return Label(verb: "Scanning", arg: grepDataArg(input))
        case "get_item":
            return Label(verb: "Fetching", arg: resolveItemTitle(input: input, appState: appState)
                ?? typeDisplay(input))
        case "create_todo":
            return Label(verb: "Creating todo:", arg: trim(string(input, "title")))
        case "create_note":
            return Label(verb: "Creating note:", arg: trim(string(input, "title")))
        case "create_idea":
            return Label(verb: "Creating idea:", arg: trim(string(input, "title")))
        case "create_reminder":
            return Label(verb: "Creating reminder:", arg: trim(string(input, "title")))
        case "create_bookmark":
            return Label(verb: "Saving bookmark:", arg: trim(string(input, "title")) ?? hostFromUrl(string(input, "url")))
        case "create_meeting":
            return Label(verb: "Creating meeting:", arg: trim(string(input, "title")))
        case "update_reminder":
            return Label(verb: "Updating reminder:", arg: trim(string(input, "title"))
                ?? resolveById(input, appState) { st, id in st.reminders.first(where: { $0.id == id })?.title })
        case "update_bookmark":
            return Label(verb: "Updating bookmark:", arg: trim(string(input, "title"))
                ?? resolveById(input, appState) { st, id in st.bookmarks.first(where: { $0.id == id })?.title })
        case "update_meeting":
            return Label(verb: "Updating meeting:", arg: trim(string(input, "title"))
                ?? resolveById(input, appState) { st, id in st.meetings.first(where: { $0.id == id })?.title })
        case "update_habit":
            return Label(verb: "Updating habit:", arg: trim(string(input, "title"))
                ?? (string(input, "habit").flatMap { UUID(uuidString: $0) == nil ? trim($0) : nil }))
        case "create_network_entry":
            return Label(verb: "Adding to Network Hub:", arg: trim(string(input, "name")) ?? trim(string(input, "company")))
        case "update_network_entry":
            return Label(verb: "Updating network entry:", arg: trim(string(input, "name"))
                ?? resolveById(input, appState) { st, id in
                    st.networkEntries.first(where: { $0.id == id }).map { $0.name.isEmpty ? $0.company : $0.name }
                })
        case "create_company":
            return Label(verb: "Creating company:", arg: trim(string(input, "name")))
        case "update_company":
            return Label(verb: "Updating company:", arg: trim(string(input, "name"))
                ?? resolveById(input, appState) { st, id in st.companies.first(where: { $0.id == id })?.name })
        case "create_event":
            return Label(verb: "Creating event:", arg: trim(string(input, "name")))
        case "update_event":
            return Label(verb: "Updating event:", arg: trim(string(input, "name"))
                ?? resolveById(input, appState) { st, id in st.events.first(where: { $0.id == id })?.name })
        case "create_community":
            return Label(verb: "Creating community:", arg: trim(string(input, "name")))
        case "update_community":
            return Label(verb: "Updating community:", arg: trim(string(input, "name"))
                ?? resolveById(input, appState) { st, id in st.communities.first(where: { $0.id == id })?.name })
        case "update_todo":
            return Label(verb: "Updating todo:", arg: trim(string(input, "title"))
                ?? resolveItemTitle(input: input, appState: appState))
        case "update_note":
            return Label(verb: "Updating note:", arg: trim(string(input, "title"))
                ?? resolveItemTitle(input: input, appState: appState))
        case "update_idea":
            return Label(verb: "Updating idea:", arg: trim(string(input, "title"))
                ?? resolveItemTitle(input: input, appState: appState))
        case "complete_todo":
            return Label(verb: "Completing todo:", arg: resolveItemTitle(input: input, appState: appState))
        case "uncomplete_todo":
            return Label(verb: "Reopening todo:", arg: resolveItemTitle(input: input, appState: appState))
        case "complete_reminder":
            return Label(verb: "Completing reminder:", arg: resolveItemTitle(input: input, appState: appState))
        case "delete_item":
            return Label(verb: "Deleting", arg: resolveItemTitle(input: input, appState: appState)
                ?? typeDisplay(input))
        case "open_url":
            return Label(verb: "Opening", arg: hostFromUrl(string(input, "url")))
        case "create_habit":
            return Label(verb: "Creating habit:", arg: trim(string(input, "title")))
        case "log_habit_entry":
            return Label(verb: "Logging habit:", arg: resolveItemTitle(input: input, appState: appState))
        case "complete_habit":
            return Label(verb: "Completing habit:", arg: resolveItemTitle(input: input, appState: appState))
        case "list_habits":
            return Label(verb: "Listing habits", arg: nil)
        case "attach_item_preview":
            return Label(verb: "Attaching preview:", arg: resolveItemTitle(input: input, appState: appState))
        case "visualize":
            return Label(verb: "Rendering:", arg: trim(string(input, "title"))
                ?? string(input, "type").map { "\($0) visualization" })
        case "read_file":
            return Label(verb: "Reading file:", arg: resolveFileName(input: input, appState: appState))
        case "create_file":
            return Label(verb: "Creating file:", arg: trim(string(input, "filename")))
        case "create_tab":
            return Label(verb: "Creating tab:", arg: trim(string(input, "name")))
        case "update_tab":
            return Label(verb: "Updating tab:", arg: resolveTabName(input, appState))
        case "get_tab":
            if let tab = resolveTabName(input, appState) {
                return Label(verb: "Reading tab:", arg: tab)
            }
            return Label(verb: "Listing custom tabs", arg: nil)
        case "set_tab_blocks":
            var arg = resolveTabName(input, appState)
            if let name = arg, let count = (input["blocks"] as? [Any])?.count {
                arg = "\(name) (\(count) block\(count == 1 ? "" : "s"))"
            }
            return Label(verb: "Building dashboard:", arg: arg)
        case "update_tab_block":
            let blockId = ((input["block"] as? [String: Any])?["id"] as? String).flatMap { trim($0) }
            let parts = [resolveTabName(input, appState), blockId].compactMap { $0 }
            return Label(verb: (input["remove"] as? Bool) == true ? "Removing block:" : "Updating dashboard:",
                         arg: parts.isEmpty ? nil : parts.joined(separator: " · "))
        case "add_tab_records":
            let count = (input["records"] as? [Any])?.count ?? 0
            return Label(verb: "Adding \(count) row\(count == 1 ? "" : "s") to", arg: resolveTabName(input, appState))
        case "update_tab_record":
            return Label(verb: "Updating row in", arg: resolveTabName(input, appState))
        default:
            // Generated custom-tab tools: create_<slug> / update_<slug>.
            if let appState,
               let (action, tab) = OttoTools.customTabTool(named: name, tabs: appState.customTabs) {
                let titleArg = tab.fieldKeys().first.flatMap { trim(string(input, $0.key)) }
                switch action {
                case .create:
                    return Label(verb: "Adding to \(tab.name):", arg: titleArg)
                case .update:
                    return Label(verb: "Updating \(tab.name):", arg: titleArg
                        ?? resolveCustomRecordTitle(input: input, appState: appState, tab: tab))
                }
            }
            return Label(verb: name.replacingOccurrences(of: "_", with: " ").capitalized, arg: nil)
        }
    }

    /// Convenience overload for paths that only have a `JSONValue` input
    /// (the rebuild-from-saved-turns path).
    @MainActor
    static func describe(name: String, input: JSONValue, appState: AppState?) -> Label {
        let dict = input.asDictionary ?? [:]
        return describe(name: name, input: dict, appState: appState)
    }

    /// One-line rendering used by history flattening.
    @MainActor
    static func oneLine(name: String, input: JSONValue, appState: AppState?) -> String {
        let label = describe(name: name, input: input, appState: appState)
        if let arg = label.arg, !arg.isEmpty {
            return "\(label.verb) \(arg)"
        }
        return label.verb
    }

    // MARK: - Argument extraction helpers

    /// "connections.csv for \"barcelona\"" — the grep_data call line.
    private static func grepDataArg(_ input: [String: Any]) -> String? {
        guard let file = string(input, "file"), !file.isEmpty else { return nil }
        if let pattern = string(input, "pattern"), !pattern.isEmpty, pattern != "." {
            return "\(file) for \"\(truncate(pattern))\""
        }
        return file
    }

    private static func string(_ input: [String: Any], _ key: String) -> String? {
        (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trim(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return truncate(s)
    }

    private static func quoted(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return "\"\(truncate(s))\""
    }

    private static func truncate(_ s: String) -> String {
        if s.count <= argMaxChars { return s }
        return String(s.prefix(argMaxChars - 1)) + "…"
    }

    private static func typeDisplay(_ input: [String: Any]) -> String? {
        guard let raw = input["type"] as? String,
              let type = OttoTools.previewContentType(raw)
        else { return nil }
        return type.displayName.lowercased()
    }

    private static func hostFromUrl(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: withScheme), let host = url.host else { return truncate(raw) }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Look up the item's title given `{ type, id }`-shaped input. AppState
    /// is `@MainActor`, so this helper inherits that isolation from its caller.
    /// Resolve a file's display name from its id alone — used by the
    /// `read_file` tool chip, whose input doesn't carry a `type` field.
    @MainActor
    private static func resolveFileName(input: [String: Any], appState: AppState?) -> String? {
        guard let appState = appState,
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr),
              let f = appState.files.first(where: { $0.id == id })
        else { return nil }
        return trim(f.name)
    }

    /// Resolve a display name from the update-tool input shape (`id` only, no
    /// `type` field) via a caller-supplied collection lookup.
    @MainActor
    private static func resolveById(
        _ input: [String: Any],
        _ appState: AppState?,
        _ lookup: (AppState, UUID) -> String?
    ) -> String? {
        guard let appState,
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return nil }
        return trim(lookup(appState, id))
    }

    /// Pretty tab name for the tab-management tools' `tab` slug/name param.
    @MainActor
    private static func resolveTabName(_ input: [String: Any], _ appState: AppState?) -> String? {
        guard let raw = string(input, "tab"), !raw.isEmpty else { return nil }
        guard let appState else { return trim(raw) }
        let lowered = raw.lowercased()
        let tab = appState.customTabs.first { $0.slug == lowered }
            ?? appState.customTabs.first { $0.name.caseInsensitiveCompare(raw) == .orderedSame }
        return trim(tab?.name ?? raw)
    }

    @MainActor
    private static func resolveCustomRecordTitle(input: [String: Any], appState: AppState, tab: CustomTabDefinition) -> String? {
        guard let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr),
              let record = appState.customRecords.first(where: { $0.id == id && $0.tabId == tab.id })
        else { return nil }
        return trim(record.displayTitle(in: tab))
    }

    @MainActor
    private static func resolveItemTitle(input: [String: Any], appState: AppState?) -> String? {
        guard let appState = appState,
              let typeStr = input["type"] as? String,
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return nil }

        // Custom-tab record? (delete_item / get_item with a custom slug type)
        if let tab = appState.customTabs.first(where: { $0.slug == typeStr }) {
            return appState.customRecords.first(where: { $0.id == id && $0.tabId == tab.id })
                .map { trim($0.displayTitle(in: tab)) } ?? nil
        }

        guard let type = OttoTools.previewContentType(typeStr) else { return nil }

        let title: String?
        switch type {
        case .todo:       title = appState.todos.first(where: { $0.id == id })?.title
        case .note:       title = appState.notes.first(where: { $0.id == id })?.title
        case .idea:       title = appState.ideas.first(where: { $0.id == id })?.title
        case .reminder:   title = appState.reminders.first(where: { $0.id == id })?.title
        case .bookmark:   title = appState.bookmarks.first(where: { $0.id == id })?.title
        case .habit:      title = appState.habits.first(where: { $0.id == id })?.title
        case .meeting:    title = appState.meetings.first(where: { $0.id == id })?.title
        case .email:      title = appState.emails.first(where: { $0.id == id })?.subject
        case .connection: title = appState.connections.first(where: { $0.id == id })?.fullName
        case .networkHub: title = appState.networkEntries.first(where: { $0.id == id }).map { $0.name.isEmpty ? $0.company : $0.name }
        case .company:    title = appState.companies.first(where: { $0.id == id })?.name
        case .event:      title = appState.events.first(where: { $0.id == id })?.name
        case .community:  title = appState.communities.first(where: { $0.id == id })?.name
        case .file:       title = appState.files.first(where: { $0.id == id })?.name
        default:          title = nil
        }
        return trim(title)
    }
}
