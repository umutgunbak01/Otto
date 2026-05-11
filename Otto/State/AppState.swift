import SwiftUI

@MainActor
private final class IncrementalSyncState {
    var existingIds: Set<String>
    var pendingCount: Int = 0
    init(existingIds: Set<String>) { self.existingIds = existingIds }
}

@Observable
final class AppState {
    // Data
    var todos: [Todo] = []
    var notes: [Note] = []
    var ideas: [Idea] = []
    var reminders: [Reminder] = []
    var bookmarks: [Bookmark] = []
    var meetings: [Meeting] = []
    var files: [FileItem] = []
    var habits: [Habit] = []
    var domainTags: [DomainTag] = []
    var importedMeetings: [ImportedMeeting] = []

    // Fireflies Integration State
    var firefliesTranscripts: [FirefliesTranscript] = []
    var isLoadingFireflies: Bool = false
    var firefliesSyncError: String?
    var firefliesSyncSettings: FirefliesSyncSettings = FirefliesSyncSettings.load()
    var lastAutoSyncResult: String?
    private var syncTimer: Timer?

    // Gmail Integration State
    var emails: [Email] = []
    var isLoadingGmail: Bool = false
    var gmailSyncError: String?
    var blockedSenders: [String] = []
    var lastGmailSync: Date?
    var isGmailConnected: Bool = false

    // Google Calendar Integration State
    var calendarEvents: [CalendarEvent] = []
    var isLoadingCalendar: Bool = false
    var calendarSyncError: String?
    var lastCalendarSync: Date?
    var isCalendarConnected: Bool = false
    var needsGoogleReauth: Bool = false

    // Todoist Integration State
    var isTodoistConnected: Bool = false
    var isLoadingTodoist: Bool = false
    var todoistSyncError: String?
    var lastTodoistSync: Date?

    // Notion Integration State
    var isNotionConnected: Bool = false
    var isLoadingNotion: Bool = false
    var notionSyncError: String?
    var lastNotionSync: Date?

    // X (Twitter) Integration State
    var xPosts: [XPost] = []
    var xFollowers: [XFollower] = []
    var xDirectMessages: [XDirectMessage] = []
    var isXConnected: Bool = false
    var isLoadingX: Bool = false
    var xSyncError: String?
    var lastXSync: Date?

    // LinkedIn Connections State
    var connections: [Connection] = []
    var isLoadingConnections: Bool = false
    var connectionImportError: String?
    var selectedConnection: Connection?

    // Ask History State
    var askHistory: [AskHistoryItem] = []

    // Chat sessions — rich (turn-level) chat history persisted across launches.
    // The active session is the one currently open in the chat sheet; nil
    // means a fresh / unsaved chat.
    var chatSessions: [ChatSession] = []
    var activeChatSessionId: UUID?


    // UI State
    var selectedTab: ContentType = .todo
    var isLoading: Bool = false
    var isProcessingInput: Bool = false
    var errorMessage: String?
    var inputText: String = ""

    /// Set by the dock input bar when the user sends a message. OttoChatView
    /// picks it up on appear, sends it, and clears the field.
    var pendingChatPrompt: String?

    // Voice mode — lifted from OttoChatView so the wake-word path can present
    // the overlay programmatically and hand it a greeting to speak on open.
    var showVoiceOverlay: Bool = false
    var pendingVoiceGreeting: String?
    /// Set once per calendar day by the wake-word path — tells the next
    /// `VoiceSessionManager.start` to run the morning-briefing prompt through
    /// Claude instead of speaking the fixed "Welcome back, boss" greeting.
    var pendingBriefing: Bool = false

    /// When non-nil and in the future, the user has asked for quiet (e.g.
    /// "silence for 25 minutes"). `NotificationService` consults this before
    /// scheduling non-critical reminders / meeting-prep pings.
    var quietUntil: Date?

    /// One-shot handoff for the screen-vision intent: IntentRouter captures a
    /// PNG of the main display and stashes its path here; `ClaudeCLIService`
    /// copies it into the CLI's tmpDir as `screenshot.png` right before spawn,
    /// then clears this back to `nil`.
    var pendingScreenshotPath: String?

    // Selected items for detail views
    var selectedTodo: Todo?
    var selectedNote: Note?
    var selectedIdea: Idea?
    var selectedBookmark: Bookmark?
    var selectedMeeting: Meeting?
    var selectedFile: FileItem?

    // Locate item (used by Home search to scroll to and select an item)
    var locateItemId: UUID?

    /// When the app launched. Drives the UPTIME counter in the Otto top bar.
    let launchDate: Date = .now

    // Services
    private let persistence = PersistenceService.shared
    let claude = AgentService.shared
    let voice = VoiceSessionManager()
    let wakeWord = WakeWordService()
    let meetingPrep = MeetingPrepService()
    private let notifications = NotificationService.shared
    private let fireflies = FirefliesService.shared
    private let gmail = GmailService.shared
    private let calendar = GoogleCalendarService.shared
    private let todoist = TodoistService.shared
    private let notion = NotionService.shared
    let undoService = UndoService()

    init() {
        // Data loading moved to MainView.task modifier for reliable loading on app launch/rebuild
        Task {
            await notifications.requestAuthorization()
        }
        // Connection status is the AND of two things:
        //   1. We actually have a Google token in the keychain.
        //   2. The user hasn't explicitly disconnected this integration.
        // Without (2) the user's "Disconnect Gmail" tap doesn't survive a
        // relaunch — keychain still has the token (Calendar shares it) so
        // we'd flip the flag right back to "Connected".
        let hasToken = GoogleAuthService.shared.isAuthenticated()
        let gmailWanted = AppState.readConnectionPreference(.gmail)
        let calendarWanted = AppState.readConnectionPreference(.calendar)
        isGmailConnected = hasToken && gmailWanted
        isCalendarConnected = hasToken && calendarWanted
        // Check Todoist connection status
        isTodoistConnected = TodoistService.shared.hasAPIToken()
        // Check Notion connection status
        isNotionConnected = NotionService.shared.hasAPIToken()
        // Check X (Twitter) connection status
        isXConnected = XAuthService.shared.isAuthenticated()
        // Start auto-sync timer if enabled
        startAutoSyncTimerIfNeeded()

        // MCP server exposing OttoTools to the `claude` CLI (Phase 2 of the
        // CLI backend swap). Safe to configure unconditionally — it only binds
        // the Unix socket if someone calls `ensureStarted()`.
        OttoMCPServer.shared.configure(appState: self)

        // Let the notification service honor `quietUntil` without plumbing it
        // through every call site.
        Task { await NotificationService.shared.configure(appState: self) }

        // Wire the meeting-prep background worker. `start()` is deferred to
        // OttoApp.task so the calendar data has a chance to load first.
        meetingPrep.configure(appState: self)
    }

    deinit {
        syncTimer?.invalidate()
    }

    // MARK: - Auto Sync Timer

    func startAutoSyncTimerIfNeeded() {
        syncTimer?.invalidate()
        syncTimer = nil

        guard firefliesSyncSettings.autoSyncEnabled,
              FirefliesService.shared.hasAPIKey(),
              !firefliesSyncSettings.userEmail.isEmpty else {
            return
        }

        // Check if we need to sync on startup
        checkAndRunAutoSync()

        // Schedule daily check (every hour we check if 24h has passed)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkAndRunAutoSync()
        }
    }

    private func checkAndRunAutoSync() {
        let settings = firefliesSyncSettings
        let intervalSeconds = TimeInterval(settings.syncIntervalHours * 3600)

        // Check if enough time has passed since last sync
        if let lastSync = settings.lastSyncDate {
            let timeSinceLastSync = Date().timeIntervalSince(lastSync)
            if timeSinceLastSync < intervalSeconds {
                return // Not time yet
            }
        }

        // Run auto-sync
        Task { @MainActor in
            await runAutoSync()
        }
    }

    func updateSyncSettings(_ settings: FirefliesSyncSettings) {
        firefliesSyncSettings = settings
        settings.save()
        startAutoSyncTimerIfNeeded()
    }

    // MARK: - Data Loading

    @MainActor
    func loadData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let store = try await persistence.load()
            todos = store.todos
            notes = store.notes
            ideas = store.ideas
            reminders = store.reminders
            bookmarks = store.bookmarks
            meetings = store.meetings
            files = store.files
            emails = store.emails
            calendarEvents = store.calendarEvents
            connections = store.connections
            askHistory = store.askHistory
            chatSessions = store.chatSessions.sorted { $0.updatedAt > $1.updatedAt }
            domainTags = store.domainTags
            importedMeetings = store.importedMeetings
            blockedSenders = store.blockedSenders
            lastGmailSync = store.lastGmailSync
            lastCalendarSync = store.lastCalendarSync
            xPosts = store.xPosts
            xFollowers = store.xFollowers
            xDirectMessages = store.xDirectMessages
            lastXSync = store.lastXSync
            habits = store.habits
        } catch {
            errorMessage = "Failed to load data: \(error.localizedDescription)"
        }

        // Backfill OG metadata for bookmarks that don't have it yet
        fetchMissingBookmarkMetadata()
    }

    // MARK: - Universal Input Processing

    /// Create an item directly from text input with a manually selected type.
    @MainActor
    func processInput(_ input: String, type: ContentType) async {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        await createItem(input: input, type: type)
    }

    @MainActor
    private func createItem(input: String, type: ContentType) async {
        switch type {
        case .todo:
            let todo = Todo(
                title: input,
                description: ""
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .note:
            let note = Note(
                title: generateTitle(from: input),
                content: input,
                primaryCategory: .personal
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .idea:
            let idea = Idea(
                title: generateTitle(from: input),
                content: input,
                primaryCategory: .personal
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            // For reminders, try to parse time from input, default to 1 hour from now
            let reminderDate = Date().addingTimeInterval(3600)
            var reminder = Reminder(
                title: input,
                reminderDate: reminderDate
            )

            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }

            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .bookmark:
            let bookmark = Bookmark(
                title: generateTitle(from: input),
                url: input,
                mediaType: .readLater,
                primaryCategory: .personal
            )
            bookmarks.insert(bookmark, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            selectedTab = .bookmark
            // Fetch OG metadata in background
            fetchBookmarkMetadata(for: bookmark.id)

        case .meeting:
            // Meetings are imported from Fireflies, not created manually
            break

        case .email:
            // Emails are imported from Gmail, not created manually
            break

        case .connection:
            // Connections are imported from LinkedIn CSV, not created manually via input
            break

        case .file:
            // Files are imported via file picker, not created manually via input
            break

        case .xPost, .xFollower, .xDm:
            // X content is imported via Integrations, not created manually via input
            break

        case .habit:
            let habit = Habit(title: input)
            habits.insert(habit, at: 0)
            try? await persistence.updateHabits(habits)
            selectedTab = .habit
        }
    }

    // MARK: - Tag Resolution

    @MainActor
    func resolveTagIds(_ tagNames: [String]) async -> [UUID] {
        var ids: [UUID] = []

        for name in tagNames {
            if let existing = domainTags.first(where: {
                $0.name.lowercased() == name.lowercased()
            }) {
                ids.append(existing.id)
                if let index = domainTags.firstIndex(where: { $0.id == existing.id }) {
                    domainTags[index].usageCount += 1
                }
            } else {
                let newTag = DomainTag(name: name, isDefault: false, usageCount: 1)
                domainTags.append(newTag)
                ids.append(newTag.id)
            }
        }

        if !tagNames.isEmpty {
            try? await persistence.updateTags(domainTags)
        }

        return ids
    }

    // MARK: - Todo Operations

    @MainActor
    func addTodo(_ todo: Todo) async {
        todos.insert(todo, at: 0)
        try? await persistence.updateTodos(todos)
        // Push to Todoist when connected. Skip if the local todo already
        // carries a Todoist id (e.g. it came from Sync, or from an undo of a
        // delete where we kept the id deliberately).
        if isTodoistConnected, todo.todoistId == nil {
            let localId = todo.id
            let snapshot = todo
            Task { @MainActor in
                do {
                    let remote = try await todoist.createTask(from: snapshot)
                    // Re-find the todo by local id — it may have moved or
                    // been edited while the network call was in flight.
                    if let i = todos.firstIndex(where: { $0.id == localId }) {
                        todos[i].todoistId = remote.id
                        try? await persistence.updateTodos(todos)
                    }
                } catch {
                    print("Failed to create Todoist task: \(error)")
                }
            }
        }
    }

    @MainActor
    func toggleTodo(_ todo: Todo) async {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[index].toggleCompletion()
        let updatedTodo = todos[index]
        try? await persistence.updateTodos(todos)
        // Sync completion status to Todoist if this is a Todoist task
        if let todoistId = updatedTodo.todoistId {
            Task {
                do {
                    if updatedTodo.isCompleted {
                        try await todoist.closeTask(id: todoistId)
                    } else {
                        try await todoist.reopenTask(id: todoistId)
                    }
                } catch {
                    print("Failed to sync completion to Todoist: \(error)")
                }
            }
        }
    }

    @MainActor
    func updateTodo(_ todo: Todo) async {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        todos[index] = todo
        todos[index].updatedAt = Date()
        let updatedTodo = todos[index]
        try? await persistence.updateTodos(todos)
        // Mirror to Todoist if linked.
        if let todoistId = updatedTodo.todoistId {
            Task {
                do {
                    try await todoist.updateTask(id: todoistId, from: updatedTodo)
                } catch {
                    print("Failed to update Todoist task: \(error)")
                }
            }
        }
    }

    @MainActor
    func deleteTodo(_ todo: Todo) async {
        // For undo we strip the Todoist id so addTodo re-creates the task
        // as a fresh row in Todoist — the original is gone the instant we
        // call deleteTask.
        var captured = todo
        captured.todoistId = nil
        undoService.pushUndo(label: "Todo deleted") { [self] in
            await self.addTodo(captured)
        }
        todos.removeAll { $0.id == todo.id }
        try? await persistence.updateTodos(todos)

        if let todoistId = todo.todoistId {
            Task {
                do {
                    try await todoist.deleteTask(id: todoistId)
                } catch {
                    print("Failed to delete Todoist task: \(error)")
                }
            }
        }
    }

    // MARK: - Todo Sub-task Operations

    @MainActor
    func addSubTask(to todoId: UUID, title: String) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
        let subTask = Todo.SubTask(title: title)
        todos[index].subTasks.append(subTask)
        todos[index].updatedAt = Date()
        let updatedTodo = todos[index]
        try? await persistence.updateTodos(todos)
    }

    @MainActor
    func toggleSubTask(todoId: UUID, subTaskId: UUID) async {
        guard let todoIndex = todos.firstIndex(where: { $0.id == todoId }),
              let subIndex = todos[todoIndex].subTasks.firstIndex(where: { $0.id == subTaskId }) else { return }
        todos[todoIndex].subTasks[subIndex].toggleCompletion()
        todos[todoIndex].updatedAt = Date()
        let updatedTodo = todos[todoIndex]
        try? await persistence.updateTodos(todos)
    }

    @MainActor
    func deleteSubTask(todoId: UUID, subTaskId: UUID) async {
        guard let todoIndex = todos.firstIndex(where: { $0.id == todoId }) else { return }
        todos[todoIndex].subTasks.removeAll { $0.id == subTaskId }
        todos[todoIndex].updatedAt = Date()
        let updatedTodo = todos[todoIndex]
        try? await persistence.updateTodos(todos)
    }

    // MARK: - Todo Tag Operations

    @MainActor
    func addTagToTodo(_ todoId: UUID, tagName: String) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
        let tagIds = await resolveTagIds([tagName])
        guard let tagId = tagIds.first else { return }
        // Avoid duplicates
        if !todos[index].domainTagIds.contains(tagId) {
            todos[index].domainTagIds.append(tagId)
            todos[index].updatedAt = Date()
            let updatedTodo = todos[index]
            try? await persistence.updateTodos(todos)
        }
    }

    @MainActor
    func removeTagFromTodo(_ todoId: UUID, tagId: UUID) async {
        guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
        todos[index].domainTagIds.removeAll { $0 == tagId }
        todos[index].updatedAt = Date()
        let updatedTodo = todos[index]
        try? await persistence.updateTodos(todos)
    }

    // MARK: - Note Operations

    @MainActor
    func addNote(_ note: Note) async {
        notes.insert(note, at: 0)
        try? await persistence.updateNotes(notes)
    }

    @MainActor
    func updateNote(_ note: Note) async {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        notes[index].updatedAt = Date()
        let updatedNote = notes[index]
        try? await persistence.updateNotes(notes)
    }

    @MainActor
    func deleteNote(_ note: Note) async {
        let captured = note
        undoService.pushUndo(label: "Note deleted") { [self] in
            await self.addNote(captured)
        }
        notes.removeAll { $0.id == note.id }
        try? await persistence.updateNotes(notes)
    }

    @MainActor
    func deleteNotes(_ ids: Set<UUID>) async {
        let captured = notes.filter { ids.contains($0.id) }
        undoService.pushUndo(label: "\(captured.count) notes deleted") { [self] in
            for note in captured {
                await self.addNote(note)
            }
        }
        notes.removeAll { ids.contains($0.id) }
        try? await persistence.updateNotes(notes)
    }

    // MARK: - Idea Operations

    @MainActor
    func addIdea(_ idea: Idea) async {
        ideas.insert(idea, at: 0)
        try? await persistence.updateIdeas(ideas)
    }

    @MainActor
    func updateIdea(_ idea: Idea) async {
        guard let index = ideas.firstIndex(where: { $0.id == idea.id }) else { return }
        ideas[index] = idea
        ideas[index].updatedAt = Date()
        let updatedIdea = ideas[index]
        try? await persistence.updateIdeas(ideas)
    }

    @MainActor
    func deleteIdea(_ idea: Idea) async {
        let captured = idea
        undoService.pushUndo(label: "Idea deleted") { [self] in
            await self.addIdea(captured)
        }
        ideas.removeAll { $0.id == idea.id }
        try? await persistence.updateIdeas(ideas)
    }

    // MARK: - Reminder Operations

    @MainActor
    func addReminder(_ reminder: Reminder) async {
        var newReminder = reminder
        // Schedule notification
        if let notificationId = try? await notifications.scheduleReminder(newReminder) {
            newReminder.notificationId = notificationId
        }
        reminders.append(newReminder)
        try? await persistence.updateReminders(reminders)
    }

    @MainActor
    func toggleReminder(_ reminder: Reminder) async {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }

        if !reminders[index].isCompleted {
            // Mark as completed
            if let notificationId = reminder.notificationId {
                await notifications.cancelReminder(notificationId: notificationId)
            }
            reminders[index].isCompleted = true
            reminders[index].completedAt = Date()
        } else {
            // Mark as incomplete - reschedule notification if in future
            reminders[index].isCompleted = false
            reminders[index].completedAt = nil
            if reminders[index].reminderDate > Date() {
                if let notificationId = try? await notifications.scheduleReminder(reminders[index]) {
                    reminders[index].notificationId = notificationId
                }
            }
        }

        let updatedReminder = reminders[index]
        try? await persistence.updateReminders(reminders)
    }

    @MainActor
    func deleteReminder(_ reminder: Reminder) async {
        let captured = reminder
        undoService.pushUndo(label: "Reminder deleted") { [self] in
            await self.addReminder(captured)
        }
        if let notificationId = reminder.notificationId {
            await notifications.cancelReminder(notificationId: notificationId)
        }
        reminders.removeAll { $0.id == reminder.id }
        try? await persistence.updateReminders(reminders)
    }

    @MainActor
    func markReminderTriggered(_ reminder: Reminder) async {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index].isTriggered = true
        let updatedReminder = reminders[index]
        try? await persistence.updateReminders(reminders)
    }

    @MainActor
    func completeReminder(_ reminder: Reminder) async {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }

        // Cancel notification if exists
        if let notificationId = reminder.notificationId {
            await notifications.cancelReminder(notificationId: notificationId)
        }

        // Mark as completed (archives it)
        reminders[index].isCompleted = true
        reminders[index].completedAt = Date()
        let updatedReminder = reminders[index]
        try? await persistence.updateReminders(reminders)
    }

    // MARK: - Bookmark Operations

    @MainActor
    func addBookmark(_ bookmark: Bookmark) async {
        bookmarks.insert(bookmark, at: 0)
        try? await persistence.updateBookmarks(bookmarks)
    }

    @MainActor
    func updateBookmark(_ bookmark: Bookmark) async {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index] = bookmark
        bookmarks[index].updatedAt = Date()
        let updatedBookmark = bookmarks[index]
        try? await persistence.updateBookmarks(bookmarks)
    }

    @MainActor
    func deleteBookmark(_ bookmark: Bookmark) async {
        let captured = bookmark
        undoService.pushUndo(label: "Bookmark deleted") { [self] in
            await self.addBookmark(captured)
        }
        bookmarks.removeAll { $0.id == bookmark.id }
        try? await persistence.updateBookmarks(bookmarks)
    }

    @MainActor
    func toggleBookmarkRead(_ bookmark: Bookmark) async {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].isRead.toggle()
        bookmarks[index].updatedAt = Date()
        let updatedBookmark = bookmarks[index]
        try? await persistence.updateBookmarks(bookmarks)
    }

    /// Fetch OG metadata for a bookmark and update it in the background
    func fetchBookmarkMetadata(for bookmarkId: UUID) {
        Task {
            guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkId }) else { return }
            let urlString = bookmarks[index].url
            guard !urlString.isEmpty, URL(string: urlString) != nil else { return }

            if let metadata = await LinkMetadataService.shared.fetchMetadata(for: urlString) {
                await MainActor.run {
                    guard let idx = bookmarks.firstIndex(where: { $0.id == bookmarkId }) else { return }
                    if let ogImage = metadata.ogImageUrl { bookmarks[idx].ogImageUrl = ogImage }
                    if let ogDesc = metadata.ogDescription { bookmarks[idx].ogDescription = ogDesc }
                    if let favicon = metadata.faviconUrl { bookmarks[idx].faviconUrl = favicon }
                    if let siteName = metadata.siteName { bookmarks[idx].siteName = siteName }
                    // Update title if it was auto-generated and OG has a better one
                    if let ogTitle = metadata.title, !ogTitle.isEmpty,
                       bookmarks[idx].title == generateTitle(from: urlString) {
                        bookmarks[idx].title = ogTitle
                    }
                    bookmarks[idx].updatedAt = Date()
                    let updated = bookmarks[idx]
                    Task {
                        try? await persistence.updateBookmarks(bookmarks)
                    }
                }
            }
        }
    }

    /// Fetch metadata for all bookmarks that don't have OG data yet
    func fetchMissingBookmarkMetadata() {
        let bookmarksNeedingMetadata = bookmarks.filter { bookmark in
            bookmark.ogImageUrl == nil && bookmark.ogDescription == nil && !bookmark.url.isEmpty
        }
        for bookmark in bookmarksNeedingMetadata.prefix(20) { // Limit to 20 at a time
            fetchBookmarkMetadata(for: bookmark.id)
        }
    }

    // MARK: - Connection Operations

    @MainActor
    func addConnection(_ connection: Connection) async {
        connections.insert(connection, at: 0)
        try? await persistence.updateConnections(connections)
    }

    @MainActor
    func updateConnection(_ connection: Connection) async {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connection
        updated.updatedAt = Date()
        connections[index] = updated
        try? await persistence.updateConnections(connections)
    }

    @MainActor
    func deleteConnection(_ connection: Connection) async {
        let captured = connection
        undoService.pushUndo(label: "Connection deleted") { [self] in
            await self.addConnection(captured)
        }
        connections.removeAll { $0.id == connection.id }
        try? await persistence.updateConnections(connections)
    }

    @MainActor
    func deleteConnections(_ ids: [UUID]) async {
        let idSet = Set(ids)
        connections.removeAll { idSet.contains($0.id) }
        try? await persistence.updateConnections(connections)
    }

    @MainActor
    func importConnectionsFromCSV(url: URL) async throws {
        isLoadingConnections = true
        connectionImportError = nil
        defer { isLoadingConnections = false }

        do {
            let importService = LinkedInImportService()
            let newConnections = try await importService.importFromCSV(url: url)

            // Deduplicate against existing connections (by name + company)
            let existingKeys = Set(connections.map { "\($0.firstName.lowercased())-\($0.lastName.lowercased())-\($0.company.lowercased())" })
            let uniqueConnections = newConnections.filter { connection in
                let key = "\(connection.firstName.lowercased())-\(connection.lastName.lowercased())-\(connection.company.lowercased())"
                return !existingKeys.contains(key)
            }

            // Add new connections
            connections.insert(contentsOf: uniqueConnections, at: 0)

            // Sort by full name
            connections.sort { $0.fullName.lowercased() < $1.fullName.lowercased() }

            try? await persistence.updateConnections(connections)

        } catch {
            connectionImportError = error.localizedDescription
            throw error
        }
    }

    // MARK: - File Operations

    @MainActor
    func addFile(_ file: FileItem) async {
        files.insert(file, at: 0)
        try? await persistence.updateFiles(files)
    }

    @MainActor
    func updateFile(_ file: FileItem) async {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        var updated = file
        updated.updatedAt = Date()
        files[index] = updated
        try? await persistence.updateFiles(files)
    }

    @MainActor
    func deleteFile(_ file: FileItem) async {
        files.removeAll { $0.id == file.id }
        // Also delete the actual file from disk
        FileStorageService.shared.deleteFile(file)
        try? await persistence.updateFiles(files)
    }

    @MainActor
    func importFile(from url: URL) async throws -> FileItem {
        let fileItem = try await FileStorageService.shared.importFile(from: url)
        await addFile(fileItem)
        return fileItem
    }

    // MARK: - Habit Operations

    @MainActor
    func addHabit(_ habit: Habit) async {
        habits.insert(habit, at: 0)
        try? await persistence.updateHabits(habits)
    }

    @MainActor
    func updateHabit(_ habit: Habit) async {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        var updated = habit
        updated.updatedAt = Date()
        habits[index] = updated
        try? await persistence.updateHabits(habits)
    }

    @MainActor
    func deleteHabit(_ habit: Habit) async {
        let captured = habit
        undoService.pushUndo(label: "Habit deleted") { [self] in
            await self.addHabit(captured)
        }
        habits.removeAll { $0.id == habit.id }
        try? await persistence.updateHabits(habits)
    }

    /// Append an entry to a habit. `value` defaults to 1 (binary tap).
    @MainActor
    func logHabitEntry(
        habitId: UUID,
        value: Double = 1,
        date: Date = Date(),
        note: String? = nil
    ) async {
        guard let index = habits.firstIndex(where: { $0.id == habitId }) else { return }
        let entry = HabitEntry(date: date, value: value, note: note)
        habits[index].entries.append(entry)
        habits[index].updatedAt = Date()
        try? await persistence.updateHabits(habits)
    }

    /// Convenience: log just enough to fulfill today's target. Used by the
    /// "✓ Complete" button on rows and the `complete_habit` chat tool.
    @MainActor
    func completeHabitToday(habitId: UUID) async {
        guard let habit = habits.first(where: { $0.id == habitId }) else { return }
        let already = habit.progress(on: Date())
        let target = max(1, habit.dailyTarget)
        let remaining = max(0, target - already)
        // For binary, always log 1 — even if already met (no-op effectively).
        let value = habit.kind == .binary ? 1 : (remaining > 0 ? remaining : target)
        await logHabitEntry(habitId: habitId, value: value)
    }

    /// Remove a single entry by id. Used by the detail view's history list.
    @MainActor
    func deleteHabitEntry(habitId: UUID, entryId: UUID) async {
        guard let index = habits.firstIndex(where: { $0.id == habitId }) else { return }
        habits[index].entries.removeAll { $0.id == entryId }
        habits[index].updatedAt = Date()
        try? await persistence.updateHabits(habits)
    }

    /// Case-insensitive contains-match used by chat tools to resolve a habit
    /// when the user references it by name ("water", "reading") instead of UUID.
    /// Prefers exact matches, then prefix, then contains. Skips archived habits.
    func findHabit(byName needle: String) -> Habit? {
        let q = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let active = habits.filter { !$0.isArchived }
        if let exact = active.first(where: { $0.title.lowercased() == q }) { return exact }
        if let prefix = active.first(where: { $0.title.lowercased().hasPrefix(q) }) { return prefix }
        return active.first(where: { $0.title.lowercased().contains(q) })
    }

    // MARK: - Ask History Operations

    @MainActor
    func addToAskHistory(messages: [ChatMessage]) async {
        let historyItem = AskHistoryItem(messages: messages)
        askHistory.insert(historyItem, at: 0)

        // Keep only the last 100 conversations
        if askHistory.count > 100 {
            askHistory = Array(askHistory.prefix(100))
        }

        try? await persistence.updateAskHistory(askHistory)
    }

    @MainActor
    func deleteAskHistoryItem(_ item: AskHistoryItem) async {
        askHistory.removeAll { $0.id == item.id }
        try? await persistence.updateAskHistory(askHistory)
    }

    @MainActor
    func clearAskHistory() async {
        let allIds = askHistory.map { $0.id }
        askHistory.removeAll()
        try? await persistence.updateAskHistory(askHistory)
    }

    // MARK: - Chat Session Operations
    //
    // The chat sheet hands AppState a snapshot of the active session's turns
    // every time the assistant finishes a turn. We upsert by id, sort by
    // recency, cap at 100, and persist. Cheap because the chat list isn't a
    // hot path.

    @MainActor
    func upsertChatSession(_ session: ChatSession) async {
        var updated = session
        updated.refreshTitle()
        updated.updatedAt = Date()

        if let idx = chatSessions.firstIndex(where: { $0.id == updated.id }) {
            chatSessions[idx] = updated
        } else {
            chatSessions.insert(updated, at: 0)
        }
        chatSessions.sort { $0.updatedAt > $1.updatedAt }
        if chatSessions.count > 100 {
            chatSessions = Array(chatSessions.prefix(100))
        }
        try? await persistence.updateChatSessions(chatSessions)
    }

    @MainActor
    func deleteChatSession(_ id: UUID) async {
        chatSessions.removeAll { $0.id == id }
        if activeChatSessionId == id { activeChatSessionId = nil }
        try? await persistence.updateChatSessions(chatSessions)
    }

    @MainActor
    func clearChatSessions() async {
        chatSessions.removeAll()
        activeChatSessionId = nil
        try? await persistence.updateChatSessions(chatSessions)
    }

    /// Look up a session by id without searching every time.
    func chatSession(_ id: UUID) -> ChatSession? {
        chatSessions.first { $0.id == id }
    }

    // MARK: - Meeting Operations

    @MainActor
    func addMeeting(_ meeting: Meeting) async {
        meetings.insert(meeting, at: 0)
        try? await persistence.updateMeetings(meetings)
    }

    @MainActor
    func updateMeeting(_ meeting: Meeting) async {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        meetings[index].updatedAt = Date()
        let updatedMeeting = meetings[index]
        try? await persistence.updateMeetings(meetings)
    }

    @MainActor
    func deleteMeeting(_ meeting: Meeting) async {
        let captured = meeting
        undoService.pushUndo(label: "Meeting deleted") { [self] in
            await self.addMeeting(captured)
        }
        meetings.removeAll { $0.id == meeting.id }
        // Also remove from imported meetings tracking
        if let firefliesId = meeting.firefliesId {
            importedMeetings.removeAll { $0.id == firefliesId }
            try? await persistence.updateImportedMeetings(importedMeetings)
        }
        try? await persistence.updateMeetings(meetings)
    }

    // MARK: - Gmail Integration

    /// Called when Gmail connection status changes (from OAuth callback)
    @MainActor
    func gmailConnectionChanged() {
        isGmailConnected = GoogleAuthService.shared.isAuthenticated()
    }

    /// Sync recent emails from Gmail
    @MainActor
    func syncGmailEmails() async {
        guard isGmailConnected else {
            gmailSyncError = "Not connected to Gmail"
            return
        }

        isLoadingGmail = true
        gmailSyncError = nil
        defer { isLoadingGmail = false }

        do {
            // Determine date range: since last sync or last 7 days
            let sinceDate: Date?
            if let lastSync = lastGmailSync {
                sinceDate = lastSync
            } else {
                sinceDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            }

            let gmailMessages = try await gmail.fetchRecentMessages(
                excludeSenders: blockedSenders,
                sinceDate: sinceDate,
                maxResults: 200
            )

            // Convert to Email models
            let newEmails = await gmail.convertToEmails(gmailMessages)

            // Filter out already imported emails (by gmailId)
            let existingIds = Set(emails.map { $0.gmailId })
            let uniqueNewEmails = newEmails.filter { !existingIds.contains($0.gmailId) }

            // Add new emails
            emails.insert(contentsOf: uniqueNewEmails, at: 0)

            // Sort by date (newest first)
            emails.sort { $0.receivedDate > $1.receivedDate }

            try? await persistence.updateEmails(emails)

            // Update last sync time
            lastGmailSync = Date()
            try? await persistence.updateLastGmailSync(lastGmailSync)

        } catch {
            if isAuthError(error) {
                handleAuthError()
                gmailSyncError = "Session expired. Please sign in again."
            } else {
                gmailSyncError = error.localizedDescription
            }
        }
    }

    /// Sync all emails from Gmail (not just since last sync)
    @MainActor
    func syncAllGmailEmails() async {
        guard isGmailConnected else {
            gmailSyncError = "Not connected to Gmail"
            return
        }

        isLoadingGmail = true
        gmailSyncError = nil
        defer { isLoadingGmail = false }

        do {
            let state = IncrementalSyncState(existingIds: Set(emails.map { $0.gmailId }))
            let persistEvery = 50

            _ = try await gmail.fetchAllMessages(
                excludeSenders: blockedSenders,
                sinceDate: nil,
                maxTotal: nil,
                batchCallback: { [weak self] batch in
                    guard let self else { return }
                    let converted = await self.gmail.convertToEmails(batch)
                    let shouldPersist: Bool = await MainActor.run {
                        var added = 0
                        for email in converted where !state.existingIds.contains(email.gmailId) {
                            state.existingIds.insert(email.gmailId)
                            self.emails.insert(email, at: 0)
                            added += 1
                        }
                        guard added > 0 else { return false }
                        self.emails.sort { $0.receivedDate > $1.receivedDate }
                        state.pendingCount += added
                        if state.pendingCount >= persistEvery {
                            state.pendingCount = 0
                            return true
                        }
                        return false
                    }
                    if shouldPersist {
                        let snapshot = await MainActor.run { self.emails }
                        try? await self.persistence.updateEmails(snapshot)
                    }
                }
            )

            // Final flush
            try? await persistence.updateEmails(emails)

            // Update last sync time
            lastGmailSync = Date()
            try? await persistence.updateLastGmailSync(lastGmailSync)

        } catch {
            if isAuthError(error) {
                handleAuthError()
                gmailSyncError = "Session expired. Please sign in again."
            } else {
                gmailSyncError = error.localizedDescription
            }
        }
    }

    /// Add an email back (used for undo)
    @MainActor
    func addEmail(_ email: Email) async {
        emails.insert(email, at: 0)
        emails.sort { $0.receivedDate > $1.receivedDate }
        try? await persistence.updateEmails(emails)
    }

    /// Delete an email
    @MainActor
    func deleteEmail(_ email: Email) async {
        let captured = email
        undoService.pushUndo(label: "Email deleted") { [self] in
            await self.addEmail(captured)
        }
        emails.removeAll { $0.id == email.id }
        try? await persistence.updateEmails(emails)
    }

    /// Delete multiple emails by their IDs
    @MainActor
    func deleteEmails(_ ids: [UUID]) async {
        let idSet = Set(ids)
        emails.removeAll { idSet.contains($0.id) }
        try? await persistence.updateEmails(emails)
    }

    /// Update an email
    @MainActor
    func updateEmail(_ email: Email) async {
        if let index = emails.firstIndex(where: { $0.id == email.id }) {
            emails[index] = email
            try? await persistence.updateEmails(emails)
        }
    }

    /// Convert email to another item type
    @MainActor
    func convertEmail(_ email: Email, to newType: ContentType) async {
        // Remove from emails
        emails.removeAll { $0.id == email.id }
        try? await persistence.updateEmails(emails)

        switch newType {
        case .todo:
            let todo = Todo(
                title: email.subject,
                description: "From: \(email.displaySender)\n\n\(email.body)"
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .note:
            let note = Note(
                title: email.subject,
                content: "From: \(email.displaySender)\nDate: \(email.formattedDate)\n\n\(email.body)",
                primaryCategory: .work
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .idea:
            let idea = Idea(
                title: email.subject,
                content: email.body,
                primaryCategory: .work
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            var reminder = Reminder(
                title: "Follow up: \(email.subject)",
                reminderDate: Date().addingTimeInterval(3600)
            )
            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }
            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .bookmark, .meeting, .email, .connection, .file, .xPost, .xFollower, .xDm, .habit:
            // Not applicable for email conversion
            break
        }
    }

    /// Add a sender to the blocked list
    @MainActor
    func addBlockedSender(_ email: String) async {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !blockedSenders.contains(normalizedEmail) else { return }

        blockedSenders.append(normalizedEmail)
        try? await persistence.updateBlockedSenders(blockedSenders)
    }

    /// Remove a sender from the blocked list
    @MainActor
    func removeBlockedSender(_ email: String) async {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        blockedSenders.removeAll { $0 == normalizedEmail }
        try? await persistence.updateBlockedSenders(blockedSenders)
    }

    /// Check if an email is from a blocked sender
    func isEmailFromBlockedSender(_ email: Email) -> Bool {
        let senderLower = email.sender.lowercased()
        return blockedSenders.contains { senderLower.contains($0) }
    }

    /// Connect to Gmail (starts OAuth flow). Always wipes any cached tokens
    /// first so we don't accidentally reuse a degraded refresh token from a
    /// prior grant — the failure mode this prevents is a "successful"
    /// reconnect that immediately 401s on the first API call.
    @MainActor
    func connectGmail() async {
        isLoadingGmail = true
        gmailSyncError = nil
        defer { isLoadingGmail = false }

        // Clear any stale tokens from a previous broken session before opening
        // the OAuth web view. We don't touch the user's emails here — those
        // were already wiped (or not) by `disconnectGmail`.
        GoogleAuthService.shared.signOut()
        // Calendar shares the same Google account, so its session is also
        // gone. Reflect that in app state so the UI doesn't lie.
        if isCalendarConnected {
            isCalendarConnected = false
            needsGoogleReauth = true
        }

        do {
            _ = try await GoogleAuthService.shared.startOAuthFlow()
            isGmailConnected = true
            AppState.writeConnectionPreference(.gmail, true)
            // OAuth covers both Gmail and Calendar scopes — restore Calendar
            // connectivity in app state so the user doesn't have to reconnect twice.
            isCalendarConnected = true
            AppState.writeConnectionPreference(.calendar, true)
            needsGoogleReauth = false
        } catch {
            gmailSyncError = error.localizedDescription
            isGmailConnected = false
            AppState.writeConnectionPreference(.gmail, false)
        }
    }

    /// Disconnect from Gmail only (keeps Calendar connected if it was)
    @MainActor
    func disconnectGmail() async {
        isGmailConnected = false
        AppState.writeConnectionPreference(.gmail, false)
        emails = []
        lastGmailSync = nil
        blockedSenders = []
        try? await persistence.updateEmails([])
        try? await persistence.updateLastGmailSync(nil)
        try? await persistence.updateBlockedSenders([])

        // If Calendar is also not connected, sign out completely
        if !isCalendarConnected {
            GoogleAuthService.shared.signOut()
        }
    }

    /// Disconnect from both Gmail and Calendar (full sign out)
    @MainActor
    func disconnectGoogle() async {
        GoogleAuthService.shared.signOut()
        isGmailConnected = false
        isCalendarConnected = false
        AppState.writeConnectionPreference(.gmail, false)
        AppState.writeConnectionPreference(.calendar, false)
        needsGoogleReauth = false
        emails = []
        calendarEvents = []
        lastGmailSync = nil
        lastCalendarSync = nil
        blockedSenders = []
        try? await persistence.updateEmails([])
        try? await persistence.updateCalendarEvents([])
        try? await persistence.updateLastGmailSync(nil)
        try? await persistence.updateLastCalendarSync(nil)
        try? await persistence.updateBlockedSenders([])
    }

    /// Re-authenticate with Google (sign out and start fresh OAuth flow)
    /// Called when refresh token is expired/revoked
    @MainActor
    func reauthenticateGoogle() async {
        // Clear old tokens
        GoogleAuthService.shared.signOut()
        needsGoogleReauth = false

        // Track what was connected before
        let wasGmailConnected = isGmailConnected
        let wasCalendarConnected = isCalendarConnected

        isGmailConnected = false
        isCalendarConnected = false

        do {
            // Start fresh OAuth flow
            _ = try await GoogleAuthService.shared.startOAuthFlow()

            // Restore previous connection state
            if wasGmailConnected {
                isGmailConnected = true
                gmailSyncError = nil
            }
            if wasCalendarConnected {
                isCalendarConnected = true
                calendarSyncError = nil
            }
        } catch {
            gmailSyncError = error.localizedDescription
            calendarSyncError = error.localizedDescription
        }
    }

    /// Check if an error is an auth error that requires re-authentication
    private func isAuthError(_ error: Error) -> Bool {
        if let authError = error as? GoogleAuthError {
            switch authError {
            case .noRefreshToken, .refreshFailed:
                return true
            default:
                return false
            }
        }
        // Also check for HTTP 401 errors from Google API
        return error.localizedDescription.contains("No refresh token") ||
               error.localizedDescription.contains("refresh access token")
    }

    /// Handle an auth error by marking re-auth needed and disconnecting
    @MainActor
    private func handleAuthError() {
        needsGoogleReauth = true
        isGmailConnected = false
        isCalendarConnected = false
        GoogleAuthService.shared.signOut()
    }

    // MARK: - Google Calendar Integration

    /// Connect to Google Calendar (starts OAuth flow if not authenticated)
    @MainActor
    func connectCalendar() async {
        isLoadingCalendar = true
        calendarSyncError = nil
        defer { isLoadingCalendar = false }

        do {
            // If already authenticated (e.g., Gmail connected), just enable calendar
            if GoogleAuthService.shared.isAuthenticated() {
                isCalendarConnected = true
                AppState.writeConnectionPreference(.calendar, true)
                // User must manually click sync to start syncing
            } else {
                // Start OAuth flow (same as Gmail, includes both scopes)
                _ = try await GoogleAuthService.shared.startOAuthFlow()
                isGmailConnected = true
                isCalendarConnected = true
                AppState.writeConnectionPreference(.gmail, true)
                AppState.writeConnectionPreference(.calendar, true)
                // User must manually click sync to start syncing
            }
        } catch {
            calendarSyncError = error.localizedDescription
            isCalendarConnected = false
        }
    }

    /// Disconnect from Google Calendar only (keeps Gmail connected if it was)
    @MainActor
    func disconnectCalendar() async {
        isCalendarConnected = false
        AppState.writeConnectionPreference(.calendar, false)
        calendarEvents = []
        lastCalendarSync = nil
        try? await persistence.updateCalendarEvents([])
        try? await persistence.updateLastCalendarSync(nil)

        // If Gmail is also not connected, sign out completely
        if !isGmailConnected {
            GoogleAuthService.shared.signOut()
        }
    }

    /// Sync calendar events (default: past 90 days to next 30 days)
    /// Past events are important for search and Ask feature
    @MainActor
    func syncCalendarEvents() async {
        guard isCalendarConnected else {
            calendarSyncError = "Not connected to Google Calendar"
            return
        }

        isLoadingCalendar = true
        calendarSyncError = nil
        defer { isLoadingCalendar = false }

        do {
            // Sync 90 days in past for search/Ask, 30 days in future for todos
            let events = try await calendar.fetchEventsRange(pastDays: 90, futureDays: 30)

            // Replace all events with fresh data
            calendarEvents = events

            // Sort by start time
            calendarEvents.sort { $0.startTime < $1.startTime }

            try? await persistence.updateCalendarEvents(calendarEvents)

            // Update last sync time
            lastCalendarSync = Date()
            try? await persistence.updateLastCalendarSync(lastCalendarSync)

        } catch {
            if isAuthError(error) {
                handleAuthError()
                calendarSyncError = "Session expired. Please sign in again."
            } else {
                calendarSyncError = error.localizedDescription
            }
        }
    }

    /// Sync calendar events for a specific date range
    @MainActor
    func syncCalendarEvents(from startDate: Date, to endDate: Date) async {
        guard isCalendarConnected else {
            calendarSyncError = "Not connected to Google Calendar"
            return
        }

        isLoadingCalendar = true
        calendarSyncError = nil
        defer { isLoadingCalendar = false }

        do {
            let events = try await calendar.fetchEvents(from: startDate, to: endDate)

            // Replace all events with fresh data
            calendarEvents = events

            // Sort by start time
            calendarEvents.sort { $0.startTime < $1.startTime }

            try? await persistence.updateCalendarEvents(calendarEvents)

            // Update last sync time
            lastCalendarSync = Date()
            try? await persistence.updateLastCalendarSync(lastCalendarSync)

        } catch {
            if isAuthError(error) {
                handleAuthError()
                calendarSyncError = "Session expired. Please sign in again."
            } else {
                calendarSyncError = error.localizedDescription
            }
        }
    }

    /// Get calendar events for a specific day
    func calendarEventsForDay(_ date: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        return calendarEvents.filter { event in
            // For all-day events, check if the date matches
            if event.isAllDay {
                return calendar.isDate(event.startTime, inSameDayAs: date)
            }
            // For timed events, check if they start on this day
            return event.startTime >= startOfDay && event.startTime < endOfDay
        }.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Todoist Integration

    /// Connect to Todoist by validating and storing the API token
    @MainActor
    func connectTodoist(apiToken: String) async {
        isLoadingTodoist = true
        todoistSyncError = nil
        defer { isLoadingTodoist = false }

        // Store token first so the service can use it
        TodoistService.shared.setAPIToken(apiToken)

        do {
            // Validate by fetching projects
            _ = try await todoist.validateToken()
            isTodoistConnected = true
            // Auto-sync tasks on connect
            await syncTodoistTasks()
        } catch {
            TodoistService.shared.clearAPIToken()
            isTodoistConnected = false
            todoistSyncError = error.localizedDescription
        }
    }

    /// Disconnect from Todoist — clears token and removes synced tasks
    @MainActor
    func disconnectTodoist() async {
        TodoistService.shared.clearAPIToken()
        isTodoistConnected = false
        todoistSyncError = nil
        lastTodoistSync = nil

        // Remove all Todoist-synced tasks from the todos array
        todos.removeAll { $0.todoistId != nil }
        try? await persistence.updateTodos(todos)
    }

    /// Sync tasks from Todoist — fetches all active tasks, deduplicates, and merges
    @MainActor
    func syncTodoistTasks() async {
        guard isTodoistConnected else {
            todoistSyncError = "Not connected to Todoist"
            return
        }

        isLoadingTodoist = true
        todoistSyncError = nil
        defer { isLoadingTodoist = false }

        do {
            // Fetch tasks and projects from Todoist
            let todoistTasks = try await todoist.fetchTasks()
            let todoistProjects = try await todoist.fetchProjects()

            // Build label map: resolve Todoist label names to DomainTag UUIDs
            let allLabelNames = Set(todoistTasks.flatMap { $0.labels ?? [] })
            var labelMap: [String: UUID] = [:]
            for labelName in allLabelNames {
                let ids = await resolveTagIds([labelName])
                if let id = ids.first {
                    labelMap[labelName.lowercased()] = id
                }
            }

            // Convert to Otto Todo models
            let newTodos = await todoist.convertToTodos(todoistTasks, projects: todoistProjects, labelMap: labelMap)

            // Remove old Todoist tasks (will be replaced with fresh data)
            todos.removeAll { $0.todoistId != nil }

            // Add fresh Todoist tasks
            todos.insert(contentsOf: newTodos, at: 0)

            // Sort: incomplete first, then by priority (descending), then by due date
            todos.sort { a, b in
                if a.isCompleted != b.isCompleted { return !a.isCompleted }
                if a.priority != b.priority { return a.priority > b.priority }
                if let aDate = a.dueDate, let bDate = b.dueDate { return aDate < bDate }
                if a.dueDate != nil { return true }
                return false
            }

            try? await persistence.updateTodos(todos)

            // Update sync timestamp
            lastTodoistSync = Date()


        } catch {
            if let todoistError = error as? TodoistError, case .unauthorized = todoistError {
                // Invalid token — disconnect
                TodoistService.shared.clearAPIToken()
                isTodoistConnected = false
                todoistSyncError = "Invalid API token. Please reconnect with a valid token."
            } else {
                todoistSyncError = error.localizedDescription
            }
        }
    }

    /// Get count of Todoist-synced tasks
    var todoistTaskCount: Int {
        todos.filter { $0.todoistId != nil }.count
    }

    // MARK: - Notion Integration

    /// Connect to Notion by validating and storing the integration token
    @MainActor
    func connectNotion(token: String) async {
        isLoadingNotion = true
        notionSyncError = nil

        NotionService.shared.setAPIToken(token)

        do {
            _ = try await notion.validateToken()
            isNotionConnected = true
            isLoadingNotion = false
            // Sync in the background after validation succeeds
            Task { await syncNotionPages() }
        } catch {
            NotionService.shared.clearAPIToken()
            isNotionConnected = false
            isLoadingNotion = false
            notionSyncError = error.localizedDescription
        }
    }

    /// Disconnect from Notion — clears token and removes synced notes
    @MainActor
    func disconnectNotion() async {
        NotionService.shared.clearAPIToken()
        isNotionConnected = false
        notionSyncError = nil
        lastNotionSync = nil

        // Remove all Notion-sourced notes
        notes.removeAll { $0.notionPageId != nil }
        try? await persistence.updateNotes(notes)
    }

    /// Sync pages from Notion — fetches all shared pages, converts to notes
    @MainActor
    func syncNotionPages() async {
        guard isNotionConnected else {
            notionSyncError = "Not connected to Notion"
            return
        }

        isLoadingNotion = true
        notionSyncError = nil
        defer { isLoadingNotion = false }

        do {
            // Fetch all pages shared with the integration
            let pages = try await notion.searchPages()
            print("[Notion] Found \(pages.count) pages")

            // Fetch blocks for each page (skip failures gracefully)
            var blocksMap: [String: [NotionBlock]] = [:]
            for page in pages {
                do {
                    let blocks = try await notion.fetchPageBlocks(pageId: page.id)
                    blocksMap[page.id] = blocks
                } catch {
                    print("[Notion] Failed to fetch blocks for page \(page.id): \(error)")
                    blocksMap[page.id] = []
                }
            }

            // Convert to Note models
            let newNotes = await notion.convertToNotes(pages, blocks: blocksMap)
            print("[Notion] Converted \(newNotes.count) notes")

            // Remove old Notion-sourced notes (replace with fresh data)
            notes.removeAll { $0.notionPageId != nil }

            // Add fresh Notion notes
            notes.insert(contentsOf: newNotes, at: 0)

            // Persist
            try? await persistence.updateNotes(notes)

            // Update sync timestamp
            lastNotionSync = Date()


        } catch {
            print("[Notion] Sync error: \(error)")
            if let notionError = error as? NotionError, case .unauthorized = notionError {
                NotionService.shared.clearAPIToken()
                isNotionConnected = false
                notionSyncError = "Invalid integration token. Please reconnect with a valid token."
            } else {
                notionSyncError = error.localizedDescription
            }
        }
    }

    /// Get count of Notion-synced notes
    var notionNoteCount: Int {
        notes.filter { $0.notionPageId != nil }.count
    }

    // MARK: - Fireflies Integration

    @MainActor
    func fetchFirefliesTranscripts() async {
        isLoadingFireflies = true
        firefliesSyncError = nil
        defer { isLoadingFireflies = false }

        do {
            firefliesTranscripts = try await fireflies.fetchTranscripts()
        } catch {
            firefliesSyncError = error.localizedDescription
        }
    }

    @MainActor
    func importFirefliesMeeting(_ transcript: FirefliesTranscript) async {
        // Check if already imported
        guard !importedMeetings.contains(where: { $0.id == transcript.id }) else {
            errorMessage = "This meeting has already been imported."
            return
        }

        isProcessingInput = true
        defer { isProcessingInput = false }

        var createdMeetingId: UUID?
        var createdTodoIds: [UUID] = []

        // 1. Create Meeting from transcript
        let suggestedTags = extractTagsFromKeywords(transcript.summary?.keywords)
        let tagIds = await resolveTagIds(suggestedTags)
        let meetingDate = transcript.dateAsDate ?? Date()

        let meeting = Meeting(
            title: transcript.title ?? "Meeting - \(transcript.formattedDate)",
            content: transcript.summary?.notes ?? "",
            overview: transcript.summary?.overview ?? "",
            actionItems: transcript.summary?.action_items ?? "",
            participants: transcript.participants ?? [],
            organizer: transcript.organizer_email ?? "",
            duration: transcript.durationInSeconds,
            meetingDate: meetingDate,
            domainTagIds: tagIds,
            firefliesId: transcript.id
        )
        meetings.insert(meeting, at: 0)
        createdMeetingId = meeting.id
        try? await persistence.updateMeetings(meetings)

        // Note: To-dos are NOT created automatically
        // Users can manually import action items from MeetingDetailView

        // 2. Track imported meeting
        let imported = ImportedMeeting(
            id: transcript.id,
            importedAt: Date(),
            meetingId: createdMeetingId,
            todoIds: [] // No todos created automatically
        )
        importedMeetings.append(imported)
        try? await persistence.updateImportedMeetings(importedMeetings)

        // Navigate to Meetings tab
        selectedTab = .meeting
    }

    /// Check if a transcript's date is within the specified number of days from now
    func isTranscriptWithinDays(_ transcript: FirefliesTranscript, days: Int) -> Bool {
        guard let date = transcript.dateAsDate else { return false }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return date >= cutoffDate
    }

    /// Create To-Dos from an already-imported meeting's action items
    @MainActor
    func createTodosFromImportedMeeting(_ transcript: FirefliesTranscript) async {
        guard let imported = importedMeetings.first(where: { $0.id == transcript.id }) else {
            errorMessage = "Meeting not found in imported meetings."
            return
        }

        // Check if todos were already created for this meeting
        guard imported.todoIds.isEmpty else {
            errorMessage = "To-Dos have already been created for this meeting."
            return
        }

        isProcessingInput = true
        defer { isProcessingInput = false }

        var createdTodoIds: [UUID] = []

        // Create Todos from action items (only for current user)
        if let actionItemsStr = transcript.summary?.action_items, !actionItemsStr.isEmpty {
            let userName = getUserNameForActionItems(from: transcript)
            let actionItems = parseActionItems(actionItemsStr, forUser: userName)
            for item in actionItems {
                let todo = Todo(
                    title: item,
                    description: "From meeting: \(transcript.title ?? "Untitled")"
                )
                todos.insert(todo, at: 0)
                createdTodoIds.append(todo.id)
            }
            try? await persistence.updateTodos(todos)
        }

        // Update the imported meeting record with the new todo IDs
        if let index = importedMeetings.firstIndex(where: { $0.id == transcript.id }) {
            let updatedImport = ImportedMeeting(
                id: imported.id,
                importedAt: imported.importedAt,
                meetingId: imported.meetingId,
                todoIds: createdTodoIds
            )
            importedMeetings[index] = updatedImport
            try? await persistence.updateImportedMeetings(importedMeetings)
        }

        // Navigate to Todos tab
        selectedTab = .todo
    }

    /// Check if todos have been created for an imported meeting
    func hasTodosForImportedMeeting(_ transcriptId: String) -> Bool {
        guard let imported = importedMeetings.first(where: { $0.id == transcriptId }) else {
            return false
        }
        return !imported.todoIds.isEmpty
    }

    /// Check if todos have been created for a meeting by its firefliesId
    func hasTodosForMeeting(_ meeting: Meeting) -> Bool {
        guard let firefliesId = meeting.firefliesId else { return false }
        return hasTodosForImportedMeeting(firefliesId)
    }

    func isTranscriptImported(_ id: String) -> Bool {
        importedMeetings.contains { $0.id == id }
    }

    /// Create To-Dos from a Meeting's action items
    @MainActor
    func createTodosFromMeeting(_ meeting: Meeting) async {
        // Check if this meeting has a fireflies ID
        guard let firefliesId = meeting.firefliesId else {
            errorMessage = "This meeting doesn't have action items to import."
            return
        }

        // Check if todos were already created
        if hasTodosForMeeting(meeting) {
            errorMessage = "To-Dos have already been created for this meeting."
            return
        }

        // Check if there are action items
        guard !meeting.actionItems.isEmpty else {
            errorMessage = "This meeting has no action items."
            return
        }

        isProcessingInput = true
        defer { isProcessingInput = false }

        var createdTodoIds: [UUID] = []

        // Get user name for filtering
        let settings = FirefliesSyncSettings.load()
        let userName: String?
        if !settings.userEmail.isEmpty {
            userName = settings.userEmail.components(separatedBy: "@").first
        } else if !meeting.organizer.isEmpty {
            userName = meeting.organizer.components(separatedBy: "@").first
        } else {
            userName = nil
        }

        // Parse and create todos
        let actionItems = parseActionItems(meeting.actionItems, forUser: userName)
        for item in actionItems {
            let todo = Todo(
                title: item,
                description: "From meeting: \(meeting.title)"
            )
            todos.insert(todo, at: 0)
            createdTodoIds.append(todo.id)
        }

        if !createdTodoIds.isEmpty {
            try? await persistence.updateTodos(todos)

            // Update the imported meeting record with the new todo IDs
            if let index = importedMeetings.firstIndex(where: { $0.id == firefliesId }) {
                let existing = importedMeetings[index]
                let updatedImport = ImportedMeeting(
                    id: existing.id,
                    importedAt: existing.importedAt,
                    meetingId: existing.meetingId,
                    todoIds: createdTodoIds
                )
                importedMeetings[index] = updatedImport
                try? await persistence.updateImportedMeetings(importedMeetings)
            }

            // Navigate to Todos tab
            selectedTab = .todo
        } else {
            errorMessage = "No action items found for you in this meeting."
        }
    }

    /// Run auto-sync: fetch meetings from last 24h (or 7 days on first run) for user's email
    @MainActor
    func runAutoSync() async {
        guard FirefliesService.shared.hasAPIKey(),
              !firefliesSyncSettings.userEmail.isEmpty else {
            return
        }

        isLoadingFireflies = true
        firefliesSyncError = nil
        defer { isLoadingFireflies = false }

        do {
            // Determine date range
            let isFirstSync = firefliesSyncSettings.lastSyncDate == nil
            let fromDate: Date
            let toDate = Date()

            if isFirstSync {
                // First sync: get last 7 days
                fromDate = Calendar.current.date(byAdding: .day, value: -7, to: toDate) ?? toDate
            } else {
                // Subsequent syncs: get since last sync
                fromDate = firefliesSyncSettings.lastSyncDate ?? toDate
            }

            // Fetch transcripts for user's email within date range
            let transcripts = try await fireflies.fetchTranscripts(
                fromDate: fromDate,
                toDate: toDate,
                participantEmail: firefliesSyncSettings.userEmail,
                limit: 50
            )

            // Filter out already imported meetings
            let newTranscripts = transcripts.filter { !isTranscriptImported($0.id) }

            var importedCount = 0
            var createdTodosCount = 0

            // Import each new meeting
            for transcript in newTranscripts {
                let result = await importMeetingSilently(transcript)
                importedCount += 1
                createdTodosCount += result.todoCount
            }

            // Update last sync date
            var settings = firefliesSyncSettings
            settings.lastSyncDate = Date()
            updateSyncSettings(settings)

            // Update result message
            if importedCount > 0 {
                lastAutoSyncResult = "Synced \(importedCount) meeting(s), created \(createdTodosCount) action item(s)"
            } else {
                lastAutoSyncResult = "No new meetings to import"
            }

        } catch {
            firefliesSyncError = error.localizedDescription
            lastAutoSyncResult = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// Import a meeting silently (for auto-sync, no navigation change)
    @MainActor
    private func importMeetingSilently(_ transcript: FirefliesTranscript) async -> (meetingId: UUID?, todoCount: Int) {
        guard !importedMeetings.contains(where: { $0.id == transcript.id }) else {
            return (nil, 0)
        }

        var createdMeetingId: UUID?
        var createdTodoIds: [UUID] = []

        // 1. Create Meeting from transcript
        let suggestedTags = extractTagsFromKeywords(transcript.summary?.keywords)
        let tagIds = await resolveTagIds(suggestedTags)
        let meetingDate = transcript.dateAsDate ?? Date()

        let meeting = Meeting(
            title: transcript.title ?? "Meeting - \(transcript.formattedDate)",
            content: transcript.summary?.notes ?? "",
            overview: transcript.summary?.overview ?? "",
            actionItems: transcript.summary?.action_items ?? "",
            participants: transcript.participants ?? [],
            organizer: transcript.organizer_email ?? "",
            duration: transcript.durationInSeconds,
            meetingDate: meetingDate,
            domainTagIds: tagIds,
            firefliesId: transcript.id
        )
        meetings.insert(meeting, at: 0)
        createdMeetingId = meeting.id
        try? await persistence.updateMeetings(meetings)

        // Note: To-dos are NOT created automatically
        // Users can manually import action items from MeetingDetailView

        // 2. Track imported meeting
        let imported = ImportedMeeting(
            id: transcript.id,
            importedAt: Date(),
            meetingId: createdMeetingId,
            todoIds: [] // No todos created automatically
        )
        importedMeetings.append(imported)
        try? await persistence.updateImportedMeetings(importedMeetings)

        return (createdMeetingId, 0)
    }

    /// Manually trigger sync now (only since last sync)
    @MainActor
    func syncFirefliesNow() async {
        await runAutoSync()
    }

    /// Sync ALL meetings from Fireflies (not just since last sync)
    @MainActor
    func syncAllFirefliesMeetings() async {
        guard FirefliesService.shared.hasAPIKey() else {
            firefliesSyncError = "No API key configured"
            return
        }

        let userEmail = firefliesSyncSettings.userEmail
        guard !userEmail.isEmpty else {
            firefliesSyncError = "No user email configured"
            return
        }

        isLoadingFireflies = true
        firefliesSyncError = nil
        defer { isLoadingFireflies = false }

        do {
            // Fetch ALL transcripts filtered by participant email (API-level filtering)
            let transcripts = try await fireflies.fetchTranscripts(participantEmail: userEmail)

            // Filter out already imported meetings
            let newTranscripts = transcripts.filter { !isTranscriptImported($0.id) }

            var importedCount = 0

            // Import each new meeting
            for transcript in newTranscripts {
                _ = await importMeetingSilently(transcript)
                importedCount += 1
            }

            // Update last sync date
            var settings = firefliesSyncSettings
            settings.lastSyncDate = Date()
            updateSyncSettings(settings)

            // Update result message
            if importedCount > 0 {
                lastAutoSyncResult = "Synced \(importedCount) meeting(s) from all time"
            } else {
                lastAutoSyncResult = "No new meetings to import"
            }

        } catch {
            firefliesSyncError = error.localizedDescription
            lastAutoSyncResult = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func extractTagsFromKeywords(_ keywords: [String]?) -> [String] {
        guard let keywords = keywords, !keywords.isEmpty else { return [] }

        let keywordList = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Map to existing domain tags when possible
        let existingTagNames = Set(domainTags.map { $0.name.lowercased() })
        var matched: [String] = []

        for keyword in keywordList {
            if existingTagNames.contains(keyword.lowercased()) {
                matched.append(keyword)
            }
        }

        // If no matches, return first 3 keywords as new tags
        if matched.isEmpty {
            return Array(keywordList.prefix(3))
        }

        return Array(matched.prefix(3))
    }

    /// Parse action items and filter to only those assigned to the current user
    /// Fireflies format: **Person Name**\nTask 1\nTask 2\n\n**Another Person**\nTask 3
    private func parseActionItems(_ actionItemsStr: String, forUser userName: String?) -> [String] {
        let lines = actionItemsStr.components(separatedBy: .newlines)
        var currentPerson: String? = nil
        var userItems: [String] = []

        // Determine if a person name matches the user
        let userNameLower = userName?.lowercased() ?? ""
        let userFirstName = userNameLower.components(separatedBy: " ").first ?? userNameLower

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if this line is a person header (e.g., "**Alice Doe**")
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") {
                let personName = trimmed
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                // Check if this person matches the user
                let personFirstName = personName.components(separatedBy: " ").first ?? personName
                currentPerson = (personName.contains(userFirstName) || personFirstName == userFirstName) ? personName : nil
                continue
            }

            // If we're in the user's section and this is a valid action item
            if currentPerson != nil && !trimmed.isEmpty && trimmed.count > 3 {
                var cleaned = trimmed
                // Remove common prefixes like "- ", "* ", "• "
                if cleaned.hasPrefix("- ") { cleaned = String(cleaned.dropFirst(2)) }
                if cleaned.hasPrefix("* ") { cleaned = String(cleaned.dropFirst(2)) }
                if cleaned.hasPrefix("• ") { cleaned = String(cleaned.dropFirst(2)) }
                // Remove numbered prefixes like "1. ", "2. "
                if let range = cleaned.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    cleaned = String(cleaned[range.upperBound...])
                }
                // Remove timestamp suffixes like "(13:18)"
                if let range = cleaned.range(of: #"\s*\(\d{1,2}:\d{2}\)\s*$"#, options: .regularExpression) {
                    cleaned = String(cleaned[..<range.lowerBound])
                }

                if !cleaned.isEmpty && cleaned.count > 3 {
                    userItems.append(cleaned)
                }
            }
        }

        return userItems
    }

    /// Get the user's name for action item filtering
    private func getUserNameForActionItems(from transcript: FirefliesTranscript) -> String? {
        // First try the sync settings user email
        let settings = FirefliesSyncSettings.load()
        if !settings.userEmail.isEmpty {
            // Extract name from email (e.g., "alice@example.com" -> "alice")
            return settings.userEmail.components(separatedBy: "@").first
        }

        // Fall back to organizer email
        if let organizer = transcript.organizer_email {
            return organizer.components(separatedBy: "@").first
        }

        return nil
    }

    @MainActor
    func createReminderForTodo(_ todo: Todo, at reminderDate: Date) async {
        var reminder = Reminder(
            title: "Reminder: \(todo.title)",
            reminderDate: reminderDate
        )

        if let notificationId = try? await notifications.scheduleReminder(reminder) {
            reminder.notificationId = notificationId
        }

        reminders.insert(reminder, at: 0)
        try? await persistence.updateReminders(reminders)
    }

    // MARK: - Item Conversion (Change Category)

    @MainActor
    func convertTodo(_ todo: Todo, to newType: ContentType) async {
        guard newType != .todo else { return }

        // Remove from todos
        todos.removeAll { $0.id == todo.id }
        try? await persistence.updateTodos(todos)

        // Create new item of target type
        switch newType {
        case .note:
            let note = Note(
                title: todo.title,
                content: todo.description,
                primaryCategory: .personal,
                domainTagIds: todo.domainTagIds
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .idea:
            let idea = Idea(
                title: todo.title,
                content: todo.description,
                primaryCategory: .personal,
                domainTagIds: todo.domainTagIds
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            let reminderDate = todo.dueDate ?? Date().addingTimeInterval(3600)
            var reminder = Reminder(
                title: todo.title,
                reminderDate: reminderDate
            )
            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }
            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .todo:
            break

        case .bookmark:
            let bookmark = Bookmark(
                title: todo.title,
                url: todo.description,
                mediaType: .readLater,
                primaryCategory: .personal
            )
            bookmarks.insert(bookmark, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            selectedTab = .bookmark
            fetchBookmarkMetadata(for: bookmark.id)

        case .meeting:
            // Cannot convert to meeting - meetings are imported from Fireflies
            break

        case .email:
            // Cannot convert to email - emails are imported from Gmail
            break

        case .connection:
            // Cannot convert to connection - connections are imported from LinkedIn
            break

        case .file:
            // Cannot convert to file - files are imported via file picker
            break

        case .xPost, .xFollower, .xDm:
            // Cannot convert to X content types - imported via Integrations
            break

        case .habit:
            // Habits are tracked separately and not produced by conversion
            break
        }
    }

    @MainActor
    func convertNote(_ note: Note, to newType: ContentType) async {
        guard newType != .note else { return }

        // Remove from notes
        notes.removeAll { $0.id == note.id }
        try? await persistence.updateNotes(notes)

        switch newType {
        case .todo:
            let todo = Todo(
                title: note.title,
                description: note.content,
                domainTagIds: note.domainTagIds
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .idea:
            let idea = Idea(
                title: note.title,
                content: note.content,
                primaryCategory: note.primaryCategory,
                domainTagIds: note.domainTagIds
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            var reminder = Reminder(
                title: note.title,
                reminderDate: Date().addingTimeInterval(3600)
            )
            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }
            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .note:
            break

        case .bookmark:
            let bookmark = Bookmark(
                title: note.title,
                url: note.content,
                mediaType: .readLater,
                primaryCategory: note.primaryCategory,
                domainTagIds: note.domainTagIds
            )
            bookmarks.insert(bookmark, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            selectedTab = .bookmark
            fetchBookmarkMetadata(for: bookmark.id)

        case .meeting:
            // Cannot convert to meeting - meetings are imported from Fireflies
            break

        case .email:
            // Cannot convert to email - emails are imported from Gmail
            break

        case .connection:
            // Cannot convert to connection - connections are imported from LinkedIn
            break

        case .file:
            // Cannot convert to file - files are imported via file picker
            break

        case .xPost, .xFollower, .xDm:
            // Cannot convert to X content types - imported via Integrations
            break

        case .habit:
            // Habits are tracked separately and not produced by conversion
            break
        }
    }

    @MainActor
    func convertIdea(_ idea: Idea, to newType: ContentType) async {
        guard newType != .idea else { return }

        // Remove from ideas
        ideas.removeAll { $0.id == idea.id }
        try? await persistence.updateIdeas(ideas)

        switch newType {
        case .todo:
            let todo = Todo(
                title: idea.title,
                description: idea.content,
                domainTagIds: idea.domainTagIds
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .note:
            var content = idea.content
            if !idea.researchPrompt.isEmpty {
                content += "\n\n---\n## Research Prompt\n\(idea.researchPrompt)"
            }
            if !idea.validationPrompt.isEmpty {
                content += "\n\n---\n## Validation Prompt\n\(idea.validationPrompt)"
            }
            let note = Note(
                title: idea.title,
                content: content,
                primaryCategory: idea.primaryCategory,
                domainTagIds: idea.domainTagIds
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .reminder:
            var reminder = Reminder(
                title: idea.title,
                reminderDate: Date().addingTimeInterval(3600)
            )
            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }
            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .idea:
            break

        case .bookmark:
            let bookmark = Bookmark(
                title: idea.title,
                url: idea.content,
                mediaType: .readLater,
                primaryCategory: idea.primaryCategory,
                domainTagIds: idea.domainTagIds
            )
            bookmarks.insert(bookmark, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            selectedTab = .bookmark
            fetchBookmarkMetadata(for: bookmark.id)

        case .meeting:
            // Cannot convert to meeting - meetings are imported from Fireflies
            break

        case .email:
            // Cannot convert to email - emails are imported from Gmail
            break

        case .connection:
            // Cannot convert to connection - connections are imported from LinkedIn
            break

        case .file:
            // Cannot convert to file - files are imported via file picker
            break

        case .xPost, .xFollower, .xDm:
            // Cannot convert to X content types - imported via Integrations
            break

        case .habit:
            // Habits are tracked separately and not produced by conversion
            break
        }
    }

    @MainActor
    func convertReminder(_ reminder: Reminder, to newType: ContentType) async {
        guard newType != .reminder else { return }

        // Cancel notification and remove from reminders
        if let notificationId = reminder.notificationId {
            await notifications.cancelReminder(notificationId: notificationId)
        }
        reminders.removeAll { $0.id == reminder.id }
        try? await persistence.updateReminders(reminders)

        switch newType {
        case .todo:
            let todo = Todo(
                title: reminder.title,
                dueDate: reminder.reminderDate
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .note:
            let note = Note(
                title: reminder.title,
                content: "Originally scheduled for: \(formatDate(reminder.reminderDate))",
                primaryCategory: .personal
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .idea:
            let idea = Idea(
                title: reminder.title,
                content: "",
                primaryCategory: .personal
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            break

        case .bookmark:
            let bookmark = Bookmark(
                title: reminder.title,
                url: "",
                mediaType: .readLater,
                primaryCategory: .personal
            )
            bookmarks.insert(bookmark, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            selectedTab = .bookmark
            fetchBookmarkMetadata(for: bookmark.id)

        case .meeting:
            // Cannot convert to meeting - meetings are imported from Fireflies
            break

        case .email:
            // Cannot convert to email - emails are imported from Gmail
            break

        case .connection:
            // Cannot convert to connection - connections are imported from LinkedIn
            break

        case .file:
            // Cannot convert to file - files are imported via file picker
            break

        case .xPost, .xFollower, .xDm:
            // Cannot convert to X content types - imported via Integrations
            break

        case .habit:
            // Habits are tracked separately and not produced by conversion
            break
        }
    }

    @MainActor
    func convertBookmark(_ bookmark: Bookmark, to newType: ContentType) async {
        guard newType != .bookmark else { return }

        // Remove from bookmarks
        bookmarks.removeAll { $0.id == bookmark.id }
        try? await persistence.updateBookmarks(bookmarks)

        switch newType {
        case .todo:
            let todo = Todo(
                title: bookmark.title,
                description: bookmark.url
            )
            todos.insert(todo, at: 0)
            try? await persistence.updateTodos(todos)
            selectedTab = .todo

        case .note:
            let note = Note(
                title: bookmark.title,
                content: "URL: \(bookmark.url)\n\n\(bookmark.description)",
                primaryCategory: bookmark.primaryCategory,
                domainTagIds: bookmark.domainTagIds
            )
            notes.insert(note, at: 0)
            try? await persistence.updateNotes(notes)
            selectedTab = .note

        case .idea:
            let idea = Idea(
                title: bookmark.title,
                content: "URL: \(bookmark.url)\n\n\(bookmark.description)",
                primaryCategory: bookmark.primaryCategory,
                domainTagIds: bookmark.domainTagIds
            )
            ideas.insert(idea, at: 0)
            try? await persistence.updateIdeas(ideas)
            selectedTab = .idea

        case .reminder:
            var reminder = Reminder(
                title: bookmark.title,
                reminderDate: Date().addingTimeInterval(3600)
            )
            if let notificationId = try? await notifications.scheduleReminder(reminder) {
                reminder.notificationId = notificationId
            }
            reminders.insert(reminder, at: 0)
            try? await persistence.updateReminders(reminders)
            selectedTab = .reminder

        case .bookmark:
            break

        case .meeting:
            // Cannot convert to meeting - meetings are imported from Fireflies
            break

        case .email:
            // Cannot convert to email - emails are imported from Gmail
            break

        case .connection:
            // Cannot convert to connection - connections are imported from LinkedIn
            break

        case .file:
            // Cannot convert to file - files are imported via file picker
            break

        case .xPost, .xFollower, .xDm:
            // Cannot convert to X content types - imported via Integrations
            break

        case .habit:
            // Habits are tracked separately and not produced by conversion
            break
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Connection preference (persisted intent)

    /// Persisted "user wants this integration on" flag. Independent of whether
    /// the OAuth token actually exists in keychain — that's a separate
    /// dimension. We AND the two together at launch time so a "Disconnect"
    /// click survives a relaunch even when the keychain still has the shared
    /// Google token.
    enum ConnectionKey: String {
        case gmail    = "connection.gmail.wanted"
        case calendar = "connection.calendar.wanted"
    }

    nonisolated static func readConnectionPreference(_ key: ConnectionKey) -> Bool {
        // Default to true so users who upgraded into this code don't see their
        // already-connected integrations flip to "disconnected" on next launch.
        if UserDefaults.standard.object(forKey: key.rawValue) == nil { return true }
        return UserDefaults.standard.bool(forKey: key.rawValue)
    }

    nonisolated static func writeConnectionPreference(_ key: ConnectionKey, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }

    // MARK: - Helpers

    private func parsePriority(_ string: String?) -> Todo.Priority {
        guard let s = string?.lowercased() else { return .medium }
        switch s {
        case "low": return .low
        case "high": return .high
        case "urgent": return .urgent
        default: return .medium
        }
    }

    private func parsePrimaryCategory(_ string: String?) -> PrimaryCategory {
        guard let s = string else { return .personal }
        return PrimaryCategory(rawValue: s) ?? .personal
    }

    private func parseMediaType(_ string: String?) -> Bookmark.MediaType {
        guard let s = string else { return .readLater }
        switch s {
        case "Watch Later": return .watchLater
        case "Listen Later": return .listenLater
        default: return .readLater
        }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let s = string else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: s) {
            return date
        }

        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fallbackFormatter.date(from: s)
    }

    private func generateTitle(from input: String) -> String {
        let words = input.split(separator: " ").prefix(5)
        let title = words.joined(separator: " ")
        return title.count < input.count ? title + "..." : title
    }

    func tag(for id: UUID) -> DomainTag? {
        domainTags.first { $0.id == id }
    }

    func tags(for ids: [UUID]) -> [DomainTag] {
        ids.compactMap { tag(for: $0) }
    }

    // MARK: - X (Twitter) Integration

    /// Connect to X by starting OAuth flow
    @MainActor
    func connectX() async {
        isLoadingX = true
        xSyncError = nil
        defer { isLoadingX = false }

        do {
            _ = try await XAuthService.shared.startOAuthFlow()
            isXConnected = true
        } catch {
            if case XAuthError.userCancelled = error {
                // User cancelled — not an error
            } else {
                xSyncError = error.localizedDescription
            }
            // Trust the keychain over the thrown error: a parallel callback
            // path may have already exchanged the code and stored a valid
            // token even though startOAuthFlow's ASWebAuthenticationSession
            // ended with `canceledLogin`.
            isXConnected = XAuthService.shared.isAuthenticated()
            return
        }

        // Try to learn the user's numeric ID — needed for the per-user
        // tweets/followers endpoints. On the Free tier `/2/users/me`
        // returns 403; swallow that, leave the user ID unset, and let
        // syncX fall through to endpoints that accept the `/users/me`
        // path shortcut (e.g. bookmarks).
        do {
            let me = try await XService.shared.fetchMe()
            XAuthService.shared.setUserId(me.id)
        } catch let error as XServiceError where error.isAccessDenied {
            print("[X] /users/me blocked by tier — bookmarks will use the `me` shortcut")
        } catch {
            print("[X] fetchMe failed (non-fatal): \(error.localizedDescription)")
        }

        await syncX()
    }

    /// Disconnect from X — clears tokens and removes synced data
    @MainActor
    func disconnectX() async {
        XAuthService.shared.signOut()
        isXConnected = false
        xSyncError = nil
        lastXSync = nil
        xPosts = []
        xFollowers = []
        xDirectMessages = []

        // Unlink any connections that were linked to X followers
        for i in connections.indices {
            connections[i].linkedXFollowerId = nil
        }

        try? await persistence.updateXPosts([])
        try? await persistence.updateXFollowers([])
        try? await persistence.updateXDirectMessages([])
        try? await persistence.updateLastXSync(nil)
        try? await persistence.updateConnections(connections)
    }

    /// Sync all X data (posts, mutual followers, bookmarks, DMs)
    @MainActor
    func syncX() async {
        guard isXConnected else {
            xSyncError = "Not connected to X"
            return
        }

        // Try to resolve the numeric user ID — required by posts/followers
        // endpoints. On the Free tier `/users/me` returns 403, in which
        // case we proceed with nil and only run endpoints that accept the
        // `/users/me/...` path shortcut (bookmarks).
        var userId = XAuthService.shared.getUserId()
        if userId == nil {
            do {
                let me = try await XService.shared.fetchMe()
                XAuthService.shared.setUserId(me.id)
                userId = me.id
            } catch {
                print("[X] Skipping user-ID-keyed endpoints — /users/me unavailable: \(error.localizedDescription)")
            }
        }

        await syncXWithUserId(userId)
    }

    @MainActor
    private func syncXWithUserId(_ userId: String?) async {
        isLoadingX = true
        xSyncError = nil
        defer { isLoadingX = false }

        var tierWarnings: [String] = []

        if let userId = userId {
            do {
                // Fetch posts
                let newPosts = try await XService.shared.fetchMyTweets(userId: userId)
                // Merge: keep existing, add new (by xPostId)
                let existingPostIds = Set(xPosts.map { $0.xPostId })
                let uniqueNewPosts = newPosts.filter { !existingPostIds.contains($0.xPostId) }
                xPosts.insert(contentsOf: uniqueNewPosts, at: 0)
                // Update existing posts with fresh engagement data
                for newPost in newPosts {
                    if let idx = xPosts.firstIndex(where: { $0.xPostId == newPost.xPostId }) {
                        xPosts[idx].likeCount = newPost.likeCount
                        xPosts[idx].retweetCount = newPost.retweetCount
                        xPosts[idx].replyCount = newPost.replyCount
                        xPosts[idx].syncUpdatedAt = Date()
                    }
                }
                xPosts.sort { $0.createdAt > $1.createdAt }
                try? await persistence.updateXPosts(xPosts)
            } catch let error as XServiceError where error.isAccessDenied {
                tierWarnings.append("Posts (needs paid X API access)")
                print("[X] Posts: access denied - needs higher API tier")
            } catch {
                if case XServiceError.rateLimited = error {
                    tierWarnings.append("Posts (rate limited, try later)")
                }
                print("[X] Failed to sync posts: \(error)")
            }

            do {
                // Fetch mutual followers
                let newFollowers = try await XService.shared.fetchMutualFollowers(userId: userId)
                // Merge: keep linked connections, update follower data
                for newFollower in newFollowers {
                    if let idx = xFollowers.firstIndex(where: { $0.xUserId == newFollower.xUserId }) {
                        // Update existing — preserve linkedConnectionId
                        let linkedId = xFollowers[idx].linkedConnectionId
                        xFollowers[idx] = newFollower
                        xFollowers[idx].linkedConnectionId = linkedId
                    } else {
                        xFollowers.append(newFollower)
                    }
                }
                xFollowers.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
                try? await persistence.updateXFollowers(xFollowers)
            } catch let error as XServiceError where error.isAccessDenied {
                tierWarnings.append("Followers (needs paid X API access)")
                print("[X] Followers: access denied - needs higher API tier")
            } catch {
                print("[X] Failed to sync followers: \(error)")
            }
        } else {
            // No numeric user ID resolved — /users/me is gated on the
            // Free tier. Posts and followers both require the ID, so
            // surface a single warning and fall through to endpoints
            // that accept the `/users/me/…` path shortcut.
            tierWarnings.append("Posts & followers (needs paid X API access — /users/me blocked)")
        }

        do {
            // Fetch bookmarks. Pass nil userId to use the `/users/me/bookmarks`
            // path shortcut — keeps bookmark sync working on the Free tier
            // even when /users/me itself is blocked.
            let newBookmarks = try await XService.shared.fetchBookmarks(userId: userId)
            let existingUrls = Set(bookmarks.map { $0.url.lowercased() })
            let uniqueNewBookmarks = newBookmarks.filter { !existingUrls.contains($0.url.lowercased()) }
            bookmarks.insert(contentsOf: uniqueNewBookmarks, at: 0)
            try? await persistence.updateBookmarks(bookmarks)
            // Fetch OG metadata for new bookmarks
            for bookmark in uniqueNewBookmarks {
                fetchBookmarkMetadata(for: bookmark.id)
            }
        } catch let error as XServiceError where error.isAccessDenied {
            tierWarnings.append("Bookmarks (needs paid X API access)")
            print("[X] Bookmarks: access denied - needs higher API tier")
        } catch {
            print("[X] Failed to sync bookmarks: \(error)")
        }

        do {
            // Fetch DMs
            let newDMs = try await XService.shared.fetchDMs()
            let existingDMIds = Set(xDirectMessages.map { $0.xMessageId })
            let uniqueNewDMs = newDMs.filter { !existingDMIds.contains($0.xMessageId) }
            xDirectMessages.insert(contentsOf: uniqueNewDMs, at: 0)
            xDirectMessages.sort { $0.createdAt > $1.createdAt }
            try? await persistence.updateXDirectMessages(xDirectMessages)
        } catch let error as XServiceError where error.isAccessDenied {
            tierWarnings.append("DMs (needs X API Pro tier)")
            print("[X] DMs: access denied - needs Pro API tier")
        } catch {
            print("[X] Failed to sync DMs: \(error)")
        }

        // Show tier warnings to user
        if !tierWarnings.isEmpty {
            xSyncError = "Some features unavailable on your X API tier: \(tierWarnings.joined(separator: ", "))"
        }

        // Update sync timestamp
        lastXSync = Date()
        try? await persistence.updateLastXSync(lastXSync)

    }

    /// Link an X follower to a LinkedIn connection
    @MainActor
    func linkFollowerToConnection(followerId: UUID, connectionId: UUID) async {
        // Update follower
        if let followerIdx = xFollowers.firstIndex(where: { $0.id == followerId }) {
            xFollowers[followerIdx].linkedConnectionId = connectionId
            xFollowers[followerIdx].syncUpdatedAt = Date()
            try? await persistence.updateXFollowers(xFollowers)
        }

        // Update connection
        if let connIdx = connections.firstIndex(where: { $0.id == connectionId }) {
            connections[connIdx].linkedXFollowerId = followerId
            connections[connIdx].updatedAt = Date()
            try? await persistence.updateConnections(connections)
        }
    }

    /// Unlink an X follower from a LinkedIn connection
    @MainActor
    func unlinkFollowerFromConnection(followerId: UUID) async {
        // Find the follower and its linked connection
        guard let followerIdx = xFollowers.firstIndex(where: { $0.id == followerId }),
              let connectionId = xFollowers[followerIdx].linkedConnectionId else { return }

        // Clear follower link
        xFollowers[followerIdx].linkedConnectionId = nil
        xFollowers[followerIdx].syncUpdatedAt = Date()
        try? await persistence.updateXFollowers(xFollowers)

        // Clear connection link
        if let connIdx = connections.firstIndex(where: { $0.id == connectionId }) {
            connections[connIdx].linkedXFollowerId = nil
            connections[connIdx].updatedAt = Date()
            try? await persistence.updateConnections(connections)
        }
    }

    /// Get the linked X follower for a connection
    func linkedFollower(for connection: Connection) -> XFollower? {
        guard let followerId = connection.linkedXFollowerId else { return nil }
        return xFollowers.first { $0.id == followerId }
    }

    /// Get the linked connection for an X follower
    func linkedConnection(for follower: XFollower) -> Connection? {
        guard let connectionId = follower.linkedConnectionId else { return nil }
        return connections.first { $0.id == connectionId }
    }

    /// Get X sync stats for display
    var xSyncStats: String {
        var parts: [String] = []
        if !xPosts.isEmpty { parts.append("\(xPosts.count) posts") }
        if !xFollowers.isEmpty { parts.append("\(xFollowers.count) followers") }
        if !xDirectMessages.isEmpty { parts.append("\(xDirectMessages.count) DMs") }
        return parts.isEmpty ? "No data synced" : parts.joined(separator: ", ")
    }

}
