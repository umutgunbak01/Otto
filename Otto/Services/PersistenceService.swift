import Foundation

struct OttoDataStore: Codable {
    var todos: [Todo]
    var notes: [Note]
    var ideas: [Idea]
    var reminders: [Reminder]
    var bookmarks: [Bookmark]
    var meetings: [Meeting]
    var files: [FileItem]
    var emails: [Email]
    var calendarEvents: [CalendarEvent]
    var connections: [Connection]
    var domainTags: [DomainTag]
    var importedMeetings: [ImportedMeeting]
    var xPosts: [XPost]
    var xFollowers: [XFollower]
    var xDirectMessages: [XDirectMessage]
    var habits: [Habit]
    var blockedSenders: [String]
    var askHistory: [AskHistoryItem]
    var chatSessions: [ChatSession]
    var lastGmailSync: Date?
    var lastCalendarSync: Date?
    var lastXSync: Date?
    var lastModified: Date

    // Custom CodingKeys to support migration from old data
    enum CodingKeys: String, CodingKey {
        case todos, notes, ideas, reminders, bookmarks, meetings, files, emails, calendarEvents, connections
        case xPosts, xFollowers, xDirectMessages, habits
        case domainTags, importedMeetings, blockedSenders, askHistory, chatSessions
        case lastGmailSync, lastCalendarSync, lastXSync, lastModified
    }

    init(
        todos: [Todo] = [],
        notes: [Note] = [],
        ideas: [Idea] = [],
        reminders: [Reminder] = [],
        bookmarks: [Bookmark] = [],
        meetings: [Meeting] = [],
        files: [FileItem] = [],
        emails: [Email] = [],
        calendarEvents: [CalendarEvent] = [],
        connections: [Connection] = [],
        xPosts: [XPost] = [],
        xFollowers: [XFollower] = [],
        xDirectMessages: [XDirectMessage] = [],
        habits: [Habit] = [],
        domainTags: [DomainTag] = DefaultTags.domain,
        importedMeetings: [ImportedMeeting] = [],
        blockedSenders: [String] = [],
        askHistory: [AskHistoryItem] = [],
        chatSessions: [ChatSession] = [],
        lastGmailSync: Date? = nil,
        lastCalendarSync: Date? = nil,
        lastXSync: Date? = nil,
        lastModified: Date = Date()
    ) {
        self.todos = todos
        self.notes = notes
        self.ideas = ideas
        self.reminders = reminders
        self.bookmarks = bookmarks
        self.meetings = meetings
        self.files = files
        self.emails = emails
        self.calendarEvents = calendarEvents
        self.connections = connections
        self.xPosts = xPosts
        self.xFollowers = xFollowers
        self.xDirectMessages = xDirectMessages
        self.habits = habits
        self.domainTags = domainTags
        self.importedMeetings = importedMeetings
        self.blockedSenders = blockedSenders
        self.askHistory = askHistory
        self.chatSessions = chatSessions
        self.lastGmailSync = lastGmailSync
        self.lastCalendarSync = lastCalendarSync
        self.lastXSync = lastXSync
        self.lastModified = lastModified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todos = try container.decode([Todo].self, forKey: .todos)
        notes = try container.decode([Note].self, forKey: .notes)
        ideas = try container.decode([Idea].self, forKey: .ideas)
        reminders = try container.decode([Reminder].self, forKey: .reminders)
        // Bookmarks may not exist in old data
        bookmarks = (try? container.decode([Bookmark].self, forKey: .bookmarks)) ?? []
        // Meetings may not exist in old data
        meetings = (try? container.decode([Meeting].self, forKey: .meetings)) ?? []
        // Files may not exist in old data
        files = (try? container.decode([FileItem].self, forKey: .files)) ?? []
        // Emails may not exist in old data
        emails = (try? container.decode([Email].self, forKey: .emails)) ?? []
        // Calendar events may not exist in old data
        calendarEvents = (try? container.decode([CalendarEvent].self, forKey: .calendarEvents)) ?? []
        // Connections may not exist in old data
        connections = (try? container.decode([Connection].self, forKey: .connections)) ?? []
        // X data may not exist in old data
        xPosts = (try? container.decode([XPost].self, forKey: .xPosts)) ?? []
        xFollowers = (try? container.decode([XFollower].self, forKey: .xFollowers)) ?? []
        xDirectMessages = (try? container.decode([XDirectMessage].self, forKey: .xDirectMessages)) ?? []
        // Habits are a newer addition — fall back to empty for older stores.
        habits = (try? container.decode([Habit].self, forKey: .habits)) ?? []
        domainTags = try container.decode([DomainTag].self, forKey: .domainTags)
        // ImportedMeetings may not exist in old data
        importedMeetings = (try? container.decode([ImportedMeeting].self, forKey: .importedMeetings)) ?? []
        // Gmail settings may not exist in old data
        blockedSenders = (try? container.decode([String].self, forKey: .blockedSenders)) ?? []
        // Ask history may not exist in old data
        askHistory = (try? container.decode([AskHistoryItem].self, forKey: .askHistory)) ?? []
        // Rich chat sessions are a newer addition than askHistory.
        chatSessions = (try? container.decode([ChatSession].self, forKey: .chatSessions)) ?? []
        lastGmailSync = try? container.decode(Date.self, forKey: .lastGmailSync)
        lastCalendarSync = try? container.decode(Date.self, forKey: .lastCalendarSync)
        lastXSync = try? container.decode(Date.self, forKey: .lastXSync)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
    }

    static let empty = OttoDataStore()
}

actor PersistenceService {
    private let fileURL: URL
    private var cachedData: OttoDataStore?

    static let shared = PersistenceService()

    private init() {
        // `urls(for:in:)` is documented to always return at least one URL on
        // macOS, but the temp-dir fallback keeps a corrupted sandbox from
        // crashing the app at launch.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let ottoDir = appSupport.appendingPathComponent("Otto", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: ottoDir,
            withIntermediateDirectories: true
        )

        self.fileURL = ottoDir.appendingPathComponent("otto_data.json")
    }

    func load() async throws -> OttoDataStore {
        if let cached = cachedData {
            return cached
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let initial = OttoDataStore.empty
            cachedData = initial
            return initial
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let store = try decoder.decode(OttoDataStore.self, from: data)
        cachedData = store
        return store
    }

    func save(_ store: OttoDataStore) async throws {
        var mutableStore = store
        mutableStore.lastModified = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(mutableStore)
        try data.write(to: fileURL, options: .atomic)
        // otto_data.json holds OAuth tokens and integration state. Lock it to
        // owner-only — otherwise a same-UID process (e.g. anything else the
        // user runs) could read every integration secret. Best-effort: don't
        // fail the save if chmod hits a quirk like a filesystem without POSIX
        // permission support.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        cachedData = mutableStore
    }

    func updateTodos(_ todos: [Todo]) async throws {
        var store = try await load()
        store.todos = todos
        try await save(store)
    }

    func updateNotes(_ notes: [Note]) async throws {
        var store = try await load()
        store.notes = notes
        try await save(store)
    }

    func updateIdeas(_ ideas: [Idea]) async throws {
        var store = try await load()
        store.ideas = ideas
        try await save(store)
    }

    func updateReminders(_ reminders: [Reminder]) async throws {
        var store = try await load()
        store.reminders = reminders
        try await save(store)
    }

    func updateTags(_ tags: [DomainTag]) async throws {
        var store = try await load()
        store.domainTags = tags
        try await save(store)
    }

    func updateBookmarks(_ bookmarks: [Bookmark]) async throws {
        var store = try await load()
        store.bookmarks = bookmarks
        try await save(store)
    }

    func updateImportedMeetings(_ meetings: [ImportedMeeting]) async throws {
        var store = try await load()
        store.importedMeetings = meetings
        try await save(store)
    }

    func updateMeetings(_ meetings: [Meeting]) async throws {
        var store = try await load()
        store.meetings = meetings
        try await save(store)
    }

    func updateFiles(_ files: [FileItem]) async throws {
        var store = try await load()
        store.files = files
        try await save(store)
    }

    func updateEmails(_ emails: [Email]) async throws {
        var store = try await load()
        store.emails = emails
        try await save(store)
    }

    func updateBlockedSenders(_ senders: [String]) async throws {
        var store = try await load()
        store.blockedSenders = senders
        try await save(store)
    }

    func updateLastGmailSync(_ date: Date?) async throws {
        var store = try await load()
        store.lastGmailSync = date
        try await save(store)
    }

    func updateCalendarEvents(_ events: [CalendarEvent]) async throws {
        var store = try await load()
        store.calendarEvents = events
        try await save(store)
    }

    func updateLastCalendarSync(_ date: Date?) async throws {
        var store = try await load()
        store.lastCalendarSync = date
        try await save(store)
    }

    func updateConnections(_ connections: [Connection]) async throws {
        var store = try await load()
        store.connections = connections
        try await save(store)
    }

    func updateAskHistory(_ history: [AskHistoryItem]) async throws {
        var store = try await load()
        store.askHistory = history
        try await save(store)
    }

    func updateChatSessions(_ sessions: [ChatSession]) async throws {
        var store = try await load()
        store.chatSessions = sessions
        try await save(store)
    }

    func updateXPosts(_ xPosts: [XPost]) async throws {
        var store = try await load()
        store.xPosts = xPosts
        try await save(store)
    }

    func updateXFollowers(_ xFollowers: [XFollower]) async throws {
        var store = try await load()
        store.xFollowers = xFollowers
        try await save(store)
    }

    func updateXDirectMessages(_ xDirectMessages: [XDirectMessage]) async throws {
        var store = try await load()
        store.xDirectMessages = xDirectMessages
        try await save(store)
    }

    func updateLastXSync(_ date: Date?) async throws {
        var store = try await load()
        store.lastXSync = date
        try await save(store)
    }

    func updateHabits(_ habits: [Habit]) async throws {
        var store = try await load()
        store.habits = habits
        try await save(store)
    }
}
