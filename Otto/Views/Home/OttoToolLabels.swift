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
    /// call; `appState` is used to resolve item ids to titles.
    @MainActor
    static func describe(name: String, input: [String: Any], appState: AppState?) -> Label {
        switch name {
        case "search_items":
            return Label(verb: "Searching for", arg: quoted(string(input, "query")))
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
            return Label(verb: "Attaching preview", arg: nil)
        case "read_file":
            return Label(verb: "Reading file:", arg: resolveFileName(input: input, appState: appState))
        default:
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
              let type = ContentType(rawValue: raw)
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

    @MainActor
    private static func resolveItemTitle(input: [String: Any], appState: AppState?) -> String? {
        guard let appState = appState,
              let typeStr = input["type"] as? String,
              let type = ContentType(rawValue: typeStr),
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return nil }

        let title: String?
        switch type {
        case .todo:     title = appState.todos.first(where: { $0.id == id })?.title
        case .note:     title = appState.notes.first(where: { $0.id == id })?.title
        case .idea:     title = appState.ideas.first(where: { $0.id == id })?.title
        case .reminder: title = appState.reminders.first(where: { $0.id == id })?.title
        case .bookmark: title = appState.bookmarks.first(where: { $0.id == id })?.title
        case .habit:    title = appState.habits.first(where: { $0.id == id })?.title
        default:        title = nil
        }
        return trim(title)
    }
}
