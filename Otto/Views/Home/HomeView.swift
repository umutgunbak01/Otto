import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState

    @State private var isSearchMode: Bool = false

    // Search state
    @State private var searchText: String = ""
    @State private var searchOptions = SearchOptions()
    @State private var selectedResult: UniversalSearchResult?
    @State private var cachedSearchResults: [UniversalSearchResult] = []
    @State private var showFilters: Bool = false

    // Selection mode state
    @State private var isSelectionMode: Bool = false
    @State private var selectedSearchResults: Set<UUID> = []
    @State private var selectedItemsCache: [UniversalSearchResult] = []
    @State private var lastSelectedIndex: Int? = nil
    @State private var isExportingPDF: Bool = false

    @FocusState private var isSearchFieldFocused: Bool

    // Callback for "Locate" functionality
    var onLocateItem: ((UniversalSearchResult) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            homeHeader
            Divider()

            if isSearchMode {
                searchContent
                    .transition(.opacity)
            } else {
                askContent
                    .transition(.opacity)
            }
        }
        .background(Theme.Colors.background)
        .sheet(item: $selectedResult) { result in
            SearchResultDetailPopup(result: result, onClose: {
                selectedResult = nil
            }, onLocate: {
                let resultToLocate = result
                selectedResult = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    locateItem(resultToLocate)
                }
            })
            .environment(appState)
        }
    }

    // MARK: - Home Header

    private var homeHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isSearchMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchMode = false
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Home")
                            .font(Theme.Typography.body)
                    }
                    .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Search")
                    .font(Theme.Typography.title)
            } else {
                Text("Home")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchMode = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Theme.Colors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)
                .help("Search")
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Ask Content

    private var askContent: some View {
        OttoChatView()
            .environment(appState)
    }

        // MARK: - Search Content

    private var searchContent: some View {
        VStack(spacing: 0) {
            // Search Bar
            searchBar

            // Selection toolbar (shown when in selection mode)
            selectionToolbar

            Divider()

            // Search Results or Welcome State
            if searchText.isEmpty && !hasActiveFilters {
                searchWelcomeState
            } else if cachedSearchResults.isEmpty {
                emptySearchState
            } else {
                searchResultsList
            }
        }
        .onChange(of: searchText) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.includeContent) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.includeArchived) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.contentTypes) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.dateFilter) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.customStartDate) { _, _ in
            updateSearchResults()
        }
        .onChange(of: searchOptions.customEndDate) { _, _ in
            updateSearchResults()
        }
    }

    private func updateSearchResults() {
        cachedSearchResults = computeFilteredResults()
    }

    private var searchBar: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    TextField("Search across all categories...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .focused($isSearchFieldFocused)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)

            // Search Options
            searchOptionsBar
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
        }
    }

    // MARK: - Search Options Bar

    private var searchOptionsBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                // Include Content Toggle
                Toggle(isOn: $searchOptions.includeContent) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                        Text("Search content")
                            .font(Theme.Typography.caption)
                    }
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif

                // Include Archived Toggle
                Toggle(isOn: $searchOptions.includeArchived) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                        Text("Include archived")
                            .font(Theme.Typography.caption)
                    }
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif

                // Filters toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilters.toggle()
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12))
                        Text("Filters")
                            .font(Theme.Typography.caption)
                        if hasActiveFilters {
                            Circle()
                                .fill(Theme.Colors.accent)
                                .frame(width: 6, height: 6)
                        }
                        Image(systemName: showFilters ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(showFilters || hasActiveFilters ? Theme.Colors.accent : Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)

                Spacer()

                // Results count
                if !searchText.isEmpty {
                    Text("\(cachedSearchResults.count) results")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                // Selection mode toggle
                Button {
                    isSelectionMode.toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 12))
                        Text(isSelectionMode ? "Done" : "Select")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(isSelectionMode ? Theme.Colors.accent : Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
            }

            // Expanded filters section
            if showFilters {
                filterSection
            }
        }
    }

    private var hasActiveFilters: Bool {
        searchOptions.dateFilter != .anytime ||
        searchOptions.contentTypes.count != ContentType.allCases.count
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Divider()

            // Category filter
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Categories")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Spacer()

                    if searchOptions.contentTypes.count != ContentType.allCases.count {
                        Button("Reset") {
                            searchOptions.contentTypes = Set(ContentType.allCases)
                        }
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.accent)
                        .buttonStyle(.plain)
                    }
                }

                FlowLayout(spacing: Theme.Spacing.xs) {
                    ForEach(ContentType.allCases, id: \.self) { type in
                        categoryFilterChip(type)
                    }
                }
            }

            // Date filter
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Date")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Spacer()

                    if searchOptions.dateFilter != .anytime {
                        Button("Reset") {
                            searchOptions.dateFilter = .anytime
                            searchOptions.customStartDate = nil
                            searchOptions.customEndDate = nil
                        }
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.accent)
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: Theme.Spacing.xs) {
                    Menu {
                        ForEach(DateFilterOption.allCases, id: \.self) { option in
                            Button {
                                searchOptions.dateFilter = option
                                if option == .custom {
                                    // Set default custom range to last 7 days
                                    let now = Date()
                                    searchOptions.customEndDate = now
                                    searchOptions.customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: now)
                                }
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if searchOptions.dateFilter == option {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "calendar")
                                .font(.system(size: 11))
                            Text(searchOptions.dateFilter.rawValue)
                                .font(Theme.Typography.caption)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(searchOptions.dateFilter != .anytime ? Theme.Colors.accent.opacity(0.1) : Color.primary.opacity(0.05))
                        .foregroundStyle(searchOptions.dateFilter != .anytime ? Theme.Colors.accent : Theme.Colors.text)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)

                    // Custom date pickers
                    if searchOptions.dateFilter == .custom {
                        HStack(spacing: Theme.Spacing.xs) {
                            DatePicker("", selection: Binding(
                                get: { searchOptions.customStartDate ?? Date() },
                                set: { searchOptions.customStartDate = $0 }
                            ), displayedComponents: .date)
                            .labelsHidden()
                            .frame(width: 100)

                            Text("to")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)

                            DatePicker("", selection: Binding(
                                get: { searchOptions.customEndDate ?? Date() },
                                set: { searchOptions.customEndDate = $0 }
                            ), displayedComponents: .date)
                            .labelsHidden()
                            .frame(width: 100)
                        }
                    }
                }
            }

            // Clear all filters button
            if hasActiveFilters {
                HStack {
                    Spacer()
                    Button {
                        searchOptions.contentTypes = Set(ContentType.allCases)
                        searchOptions.dateFilter = .anytime
                        searchOptions.customStartDate = nil
                        searchOptions.customEndDate = nil
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                            Text("Clear All Filters")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, Theme.Spacing.sm)
    }

    private func categoryFilterChip(_ type: ContentType) -> some View {
        let isSelected = searchOptions.contentTypes.contains(type)

        return Button {
            if isSelected {
                // Don't allow deselecting all
                if searchOptions.contentTypes.count > 1 {
                    searchOptions.contentTypes.remove(type)
                }
            } else {
                searchOptions.contentTypes.insert(type)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: type.iconName)
                    .font(.system(size: 10))
                Text(type.displayName)
                    .font(Theme.Typography.small)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(isSelected ? type.color.opacity(0.15) : Color.primary.opacity(0.05))
            .foregroundStyle(isSelected ? type.color : Theme.Colors.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection Toolbar

    @ViewBuilder
    private var selectionToolbar: some View {
        if isSelectionMode {
            HStack(spacing: Theme.Spacing.md) {
                Text("\(selectedSearchResults.count) item\(selectedSearchResults.count == 1 ? "" : "s") selected")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(selectedSearchResults.isEmpty ? Theme.Colors.tertiaryText : Theme.Colors.accent)

                Spacer()

                if !selectedSearchResults.isEmpty {
                    Button {
                        exportSelectedItemsToPDF()
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if isExportingPDF {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 11))
                            }
                            Text("Export PDF")
                                .font(Theme.Typography.caption)
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.accent.opacity(0.1))
                        .foregroundStyle(Theme.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExportingPDF)

                    Button {
                        selectedSearchResults.removeAll()
                        selectedItemsCache.removeAll()
                        lastSelectedIndex = nil
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                            Text("Clear")
                                .font(Theme.Typography.caption)
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.secondaryBackground)
        }
    }

    // MARK: - PDF Export

    private func exportSelectedItemsToPDF() {
        guard !selectedItemsCache.isEmpty else { return }
        isExportingPDF = true

        let items = selectedItemsCache
        let exportTitle = searchText.isEmpty ? "Otto Export" : "Otto Export — \(searchText)"

        Task.detached(priority: .userInitiated) {
            guard let fileURL = PDFExportService.exportToTempFile(from: items, title: exportTitle) else {
                await MainActor.run { isExportingPDF = false }
                return
            }

            await MainActor.run {
                isExportingPDF = false

                #if os(macOS)
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.pdf]
                savePanel.nameFieldStringValue = fileURL.lastPathComponent
                savePanel.canCreateDirectories = true
                savePanel.title = "Save Otto Export PDF"

                if savePanel.runModal() == .OK, let destURL = savePanel.url {
                    try? FileManager.default.removeItem(at: destURL)
                    try? FileManager.default.copyItem(at: fileURL, to: destURL)

                    // Open in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                }
                #else
                // iOS: present share sheet — handled separately if needed
                #endif
            }
        }
    }

    // MARK: - Search Results

    private func computeFilteredResults() -> [UniversalSearchResult] {
        // Allow browsing with filters even without search text
        let hasTextQuery = !searchText.isEmpty
        let query = searchText.lowercased()
        var results: [UniversalSearchResult] = []

        // Get date range if date filter is active
        let dateRange = searchOptions.dateRange

        // Helper function to check date filter
        func matchesDateFilter(_ date: Date) -> Bool {
            guard let range = dateRange else { return true }
            return date >= range.start && date < range.end
        }

        // Search Todos (if content type is selected)
        if searchOptions.contentTypes.contains(.todo) {
            for todo in appState.todos {
                if !searchOptions.includeArchived && todo.isCompleted { continue }

                // Check date filter (use due date if available, otherwise updatedAt)
                let dateToCheck = todo.dueDate ?? todo.updatedAt
                if !matchesDateFilter(dateToCheck) { continue }

                // If no text query, include all (filtered by other criteria)
                if !hasTextQuery || matchesQuery(title: todo.title, content: searchOptions.includeContent ? todo.description : nil, query: query) {
                    results.append(.from(todo))
                }
            }

            // Also include calendar events in todo searches
            for event in appState.calendarEvents {
                if !searchOptions.includeArchived && event.isPast { continue }
                if !matchesDateFilter(event.startTime) { continue }

                let content = searchOptions.includeContent ? [event.description, event.location].compactMap { $0 }.joined(separator: " ") : nil
                if !hasTextQuery || matchesQuery(title: event.title, content: content, query: query) {
                    results.append(.from(event))
                }
            }
        }

        // Search Notes
        if searchOptions.contentTypes.contains(.note) {
            for note in appState.notes {
                if !matchesDateFilter(note.updatedAt) { continue }
                if !hasTextQuery || matchesQuery(title: note.title, content: searchOptions.includeContent ? note.content : nil, query: query) {
                    results.append(.from(note))
                }
            }
        }

        // Search Ideas
        if searchOptions.contentTypes.contains(.idea) {
            for idea in appState.ideas {
                if !searchOptions.includeArchived && idea.status == .archived { continue }
                if !matchesDateFilter(idea.updatedAt) { continue }
                if !hasTextQuery || matchesQuery(title: idea.title, content: searchOptions.includeContent ? idea.content : nil, query: query) {
                    results.append(.from(idea))
                }
            }
        }

        // Search Reminders
        if searchOptions.contentTypes.contains(.reminder) {
            for reminder in appState.reminders {
                if !searchOptions.includeArchived && reminder.isCompleted { continue }
                if !matchesDateFilter(reminder.reminderDate) { continue }
                if !hasTextQuery || matchesQuery(title: reminder.title, content: nil, query: query) {
                    results.append(.from(reminder))
                }
            }
        }

        // Search Bookmarks
        if searchOptions.contentTypes.contains(.bookmark) {
            for bookmark in appState.bookmarks {
                if !searchOptions.includeArchived && bookmark.isRead { continue }
                if !matchesDateFilter(bookmark.updatedAt) { continue }
                let content = searchOptions.includeContent ? [bookmark.description, bookmark.url].joined(separator: " ") : nil
                if !hasTextQuery || matchesQuery(title: bookmark.title, content: content, query: query) {
                    results.append(.from(bookmark))
                }
            }
        }

        // Search Meetings
        if searchOptions.contentTypes.contains(.meeting) {
            for meeting in appState.meetings {
                if !matchesDateFilter(meeting.meetingDate) { continue }
                let content = searchOptions.includeContent ? [meeting.overview, meeting.content, meeting.actionItems].joined(separator: " ") : nil
                if !hasTextQuery || matchesQuery(title: meeting.title, content: content, query: query) {
                    results.append(.from(meeting))
                }
            }
        }

        // Search Emails
        if searchOptions.contentTypes.contains(.email) {
            for email in appState.emails {
                if !searchOptions.includeArchived && email.isRead { continue }
                if !matchesDateFilter(email.receivedDate) { continue }
                let content = searchOptions.includeContent ? [email.body, email.snippet].compactMap { $0 }.joined(separator: " ") : nil
                if !hasTextQuery || matchesQuery(title: email.subject, content: content, query: query) {
                    results.append(.from(email))
                }
            }
        }

        // Search Connections
        if searchOptions.contentTypes.contains(.connection) {
            for connection in appState.connections {
                let dateToCheck = connection.connectionDate ?? connection.importedAt
                if !matchesDateFilter(dateToCheck) { continue }
                let content = searchOptions.includeContent ? connection.searchableContent : nil
                if !hasTextQuery || matchesQuery(title: connection.fullName, content: content, query: query) {
                    results.append(.from(connection))
                }
            }
        }

        // Search Files
        if searchOptions.contentTypes.contains(.file) {
            for file in appState.files {
                if !matchesDateFilter(file.updatedAt) { continue }
                let content = searchOptions.includeContent ? [file.notes, file.extractedText ?? "", file.tags.joined(separator: " ")].joined(separator: " ") : nil
                if !hasTextQuery || matchesQuery(title: file.name, content: content, query: query) {
                    results.append(.from(file))
                }
            }
        }

        // Sort by date (most recent first)
        return results.sorted { $0.date > $1.date }
    }

    private func matchesQuery(title: String, content: String?, query: String) -> Bool {
        if title.lowercased().contains(query) {
            return true
        }
        if let content = content, content.lowercased().contains(query) {
            return true
        }
        return false
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(cachedSearchResults) { result in
                    SearchResultRowView(
                        result: result,
                        searchQuery: searchText,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedSearchResults.contains(result.id),
                        onSelect: {
                            selectedResult = result
                        },
                        onToggleSelection: { withShift in
                            toggleSelection(result.id, withShift: withShift)
                        }
                    )
                    .contextMenu {
                        Button {
                            selectedResult = result
                        } label: {
                            Label("Open Details", systemImage: "doc.text")
                        }

                        Button {
                            locateItem(result)
                        } label: {
                            Label("Locate in Category", systemImage: "arrow.right.circle")
                        }

                        if isSelectionMode {
                            Divider()
                            Button {
                                toggleSelection(result.id, withShift: false)
                            } label: {
                                if selectedSearchResults.contains(result.id) {
                                    Label("Deselect", systemImage: "checkmark.circle")
                                } else {
                                    Label("Select", systemImage: "circle")
                                }
                            }
                        }
                    }

                    if result.id != cachedSearchResults.last?.id {
                        Divider()
                            .padding(.horizontal, Theme.Spacing.xl)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func toggleSelection(_ id: UUID, withShift: Bool = false) {
        // Find the current index in cached results
        let currentIndex = cachedSearchResults.firstIndex { $0.id == id }

        // Handle shift+click for range selection
        if withShift, let lastIndex = lastSelectedIndex, let currIndex = currentIndex {
            let startIndex = min(lastIndex, currIndex)
            let endIndex = max(lastIndex, currIndex)

            // Select all items in the range
            for i in startIndex...endIndex {
                let item = cachedSearchResults[i]
                if !selectedSearchResults.contains(item.id) {
                    selectedSearchResults.insert(item.id)
                    selectedItemsCache.append(item)
                }
            }
        } else {
            // Normal toggle behavior
            if selectedSearchResults.contains(id) {
                selectedSearchResults.remove(id)
                selectedItemsCache.removeAll { $0.id == id }
            } else {
                selectedSearchResults.insert(id)
                // Add the actual item to cache so it persists even if search is cleared
                if let item = cachedSearchResults.first(where: { $0.id == id }) {
                    selectedItemsCache.append(item)
                }
            }
        }

        // Update last selected index for next shift+click
        lastSelectedIndex = currentIndex

    }

    // MARK: - Search Welcome State

    private var searchWelcomeState: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Search Your Otto")
                    .font(Theme.Typography.title)

                Text("Find anything across todos, notes, ideas, reminders, bookmarks, meetings, and emails.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Quick stats
            HStack(spacing: Theme.Spacing.xl) {
                statBadge(count: appState.todos.count, label: "Todos", contentType: .todo)
                statBadge(count: appState.notes.count, label: "Notes", contentType: .note)
                statBadge(count: appState.ideas.count, label: "Ideas", contentType: .idea)
                statBadge(count: appState.emails.count, label: "Emails", contentType: .email)
            }
            .padding(.top, Theme.Spacing.lg)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statBadge(count: Int, label: String, contentType: ContentType) -> some View {
        Button {
            searchOptions.contentTypes = [contentType]
            isSearchFieldFocused = true
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: contentType.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(contentType.color)

                Text("\(count)")
                    .font(Theme.Typography.headline)

                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(width: 70)
            .padding(.vertical, Theme.Spacing.sm)
            .background(contentType.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .help("Filter search to \(label)")
    }

    // MARK: - Empty Search State

    private var emptySearchState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.sm) {
                Text("No results found")
                    .font(Theme.Typography.headline)

                if hasActiveFilters && searchText.isEmpty {
                    Text("No items match your current filters. Try adjusting your category or date filters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                } else {
                    Text("Try a different search term, enable \"Search content\" to search within item contents, or adjust your filters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Locate Item

    private func locateItem(_ result: UniversalSearchResult) {
        onLocateItem?(result)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .frame(width: 700, height: 600)
}
