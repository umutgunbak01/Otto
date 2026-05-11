import Foundation

/// Catalogue of tools exposed to Claude for unified Home input.
/// Each entry is a dictionary directly serializable to the Anthropic `tools` array.
enum OttoTools {

    /// Compile-time set of tool names. Executor switches on these.
    enum Name: String {
        case create_todo, create_note, create_idea, create_reminder, create_bookmark
        case update_todo, update_note, update_idea
        case complete_todo, uncomplete_todo, complete_reminder
        case delete_item
        case search_items, get_item
        case attach_item_preview
        case open_url
        case create_habit, log_habit_entry, complete_habit, list_habits
        case read_file
    }

    /// The array of tool definitions sent with every chat request.
    static let all: [[String: Any]] = [
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
                        ["todo", "note", "idea", "reminder", "bookmark", "habit", "file"],
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
            )
        ],

        // MARK: Search / fetch
        [
            "name": Name.search_items.rawValue,
            "description": "Search and/or list items with optional text match, date range, and sort order. Returns id, type, title, a short snippet, and the 'date' each result was ranked by. Use get_item for full content, or `read_file` for the full text of `file` items. You can call this with NO query to simply list items by date — e.g. 'most recent emails', 'reminders due next', 'notes from last week', 'files I imported'.",
            "input_schema": objectSchema(
                properties: [
                    "query": stringProp("Optional free-text query (case-insensitive substring match on title/content; also matches file names, tags, and OCR'd / extracted text). Omit to list everything matching the other filters."),
                    "types": [
                        "type": "array",
                        "description": "Limit to these types. Default: all of (todo, note, idea, reminder, bookmark, meeting, email, connection, file). `file` covers user-imported PDFs / CSVs / images / text files.",
                        "items": [
                            "type": "string",
                            "enum": ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "habit", "file"]
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
            "name": Name.get_item.rawValue,
            "description": "Fetch full details of a single item by id and type. For files, returns metadata plus a short text preview — use `read_file` for the full extracted content.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the item."),
                    "type": enumProp(
                        ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "habit", "file"],
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
            )
        ],
        [
            "name": Name.attach_item_preview.rawValue,
            "description": "Attach a clickable preview card for a specific item to your response so the user can open it in the relevant tab with one click. Use this whenever you reference an existing item by name — much better UX than quoting the title in text. You can call this multiple times in one turn to attach several cards.",
            "input_schema": objectSchema(
                properties: [
                    "id": stringProp("UUID of the item (from search_items or get_item)."),
                    "type": enumProp(
                        ["todo", "note", "idea", "reminder", "bookmark", "meeting", "email", "connection", "habit", "file"],
                        "Which collection the item lives in."
                    )
                ],
                required: ["id", "type"]
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
        ]
    ]

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
