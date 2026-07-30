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
    @State private var expandedSections: Set<ContentType> = []
    @State private var recentItems: [UniversalSearchResult] = []

    // Selection mode state
    @State private var isSelectionMode: Bool = false
    @State private var selectedSearchResults: Set<UUID> = []
    @State private var selectedItemsCache: [UniversalSearchResult] = []
    @State private var lastSelectedIndex: Int? = nil
    @State private var isExportingPDF: Bool = false

    @FocusState private var isSearchFieldFocused: Bool

    // Callback for "Locate" functionality

    var body: some View {
        VStack(spacing: 0) {
            if isSearchMode {
                homeHeader
                OttoDivider()
                searchContent
                    .transition(.opacity)
            } else {
                askContent
                    .transition(.opacity)
            }
        }
        .onChange(of: appState.homeSearchRequested) { _, requested in
            // One-shot request from the top bar's ⌘K search pill.
            if requested {
                appState.homeSearchRequested = false
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSearchMode = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isSearchFieldFocused = true
                }
            }
        }
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
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSearchMode = false
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Home")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)

            Text("Search")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Ask Content

    private var askContent: some View {
        HStack(spacing: 0) {
            if appState.showChatHistory {
                ChatHistorySidebar()
                    .environment(appState)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            OttoChatView()
                .environment(appState)
        }
    }

        // MARK: - Search Content

    private var searchContent: some View {
        VStack(spacing: 0) {
            // Search Bar
            searchBar

            // Selection toolbar (shown when in selection mode)
            selectionToolbar

            OttoDivider()

            // Search Results or Welcome State
            if searchText.isEmpty && !hasActiveFilters {
                searchWelcomeState
            } else if cachedSearchResults.isEmpty {
                emptySearchState
            } else {
                searchResultsList
            }
        }
        #if os(macOS)
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSearchMode = false
                }
            }
        }
        #endif
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
        expandedSections.removeAll()
        cachedSearchResults = computeFilteredResults()
    }

    private var searchBar: some View {
        VStack(spacing: Theme.Spacing.md) {
            searchField
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)

            categoryChipsRow
                .padding(.horizontal, Theme.Spacing.xl)

            searchOptionsRow
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSearchFieldFocused ? Theme.Colors.accentText : Theme.Colors.tertiaryText)

            TextField("Search todos, notes, meetings, emails…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(
                    isSearchFieldFocused ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.border,
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isSearchFieldFocused)
    }

    // MARK: - Category Chips

    private var allCategoriesSelected: Bool {
        searchOptions.contentTypes == Set(ContentType.searchable)
    }

    private var categoryChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(
                    label: "All",
                    icon: nil,
                    isSelected: allCategoriesSelected,
                    tint: Theme.Colors.accentText
                ) {
                    searchOptions.contentTypes = Set(ContentType.searchable)
                }

                ForEach(ContentType.searchable) { type in
                    scopeChip(
                        label: type.searchGroupName,
                        icon: type.iconName,
                        isSelected: !allCategoriesSelected && searchOptions.contentTypes.contains(type),
                        tint: type.color
                    ) {
                        toggleCategory(type)
                    }
                }
            }
        }
    }

    private func scopeChip(
        label: String,
        icon: String?,
        isSelected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? tint.opacity(0.14) : Theme.Colors.panel))
            .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.45) : Theme.Colors.border, lineWidth: 1))
            .foregroundStyle(isSelected ? tint : Theme.Colors.textDim)
        }
        .buttonStyle(.plain)
    }

    private func toggleCategory(_ type: ContentType) {
        let all = Set(ContentType.searchable)
        if searchOptions.contentTypes == all {
            // From "everything" state, clicking a chip focuses on it.
            searchOptions.contentTypes = [type]
        } else if searchOptions.contentTypes.contains(type) {
            searchOptions.contentTypes.remove(type)
            if searchOptions.contentTypes.isEmpty {
                searchOptions.contentTypes = all
            }
        } else {
            searchOptions.contentTypes.insert(type)
        }
    }

    // MARK: - Search Options Row

    private var searchOptionsRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            optionChip(
                icon: "doc.text.magnifyingglass",
                label: "Search content",
                isOn: $searchOptions.includeContent,
                help: "Also match inside item contents, not just titles"
            )

            optionChip(
                icon: "archivebox",
                label: "Include archived",
                isOn: $searchOptions.includeArchived,
                help: "Include completed, read, and archived items"
            )

            dateFilterChip

            if searchOptions.dateFilter == .custom {
                customDateRangePickers
            }

            Spacer()

            if !searchText.isEmpty || hasActiveFilters {
                Text("\(cachedSearchResults.count) result\(cachedSearchResults.count == 1 ? "" : "s")")
                    .font(Theme.Typography.monoCaption)
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
                .foregroundStyle(isSelectionMode ? Theme.Colors.accentText : Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
            .help("Select items to export")
        }
    }

    private func optionChip(icon: String, label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isOn.wrappedValue ? Theme.Colors.selectTint : Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    isOn.wrappedValue ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.border,
                    lineWidth: 1
                )
            )
            .foregroundStyle(isOn.wrappedValue ? Theme.Colors.accentText : Theme.Colors.textDim)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var dateFilterChip: some View {
        Menu {
            ForEach(DateFilterOption.allCases, id: \.self) { option in
                Button {
                    searchOptions.dateFilter = option
                    if option == .custom {
                        // Set default custom range to last 7 days
                        let now = Date()
                        searchOptions.customEndDate = now
                        searchOptions.customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: now)
                    } else {
                        searchOptions.customStartDate = nil
                        searchOptions.customEndDate = nil
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
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                Text(searchOptions.dateFilter.rawValue)
                    .font(Theme.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(searchOptions.dateFilter != .anytime ? Theme.Colors.selectTint : Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    searchOptions.dateFilter != .anytime ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.border,
                    lineWidth: 1
                )
            )
            .foregroundStyle(searchOptions.dateFilter != .anytime ? Theme.Colors.accentText : Theme.Colors.textDim)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by date")
    }

    private var customDateRangePickers: some View {
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

    private var hasActiveFilters: Bool {
        searchOptions.dateFilter != .anytime || !allCategoriesSelected
    }

    private func clearAllFilters() {
        searchOptions.contentTypes = Set(ContentType.searchable)
        searchOptions.dateFilter = .anytime
        searchOptions.customStartDate = nil
        searchOptions.customEndDate = nil
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

        // Search Notes (trashed ones stay out of search)
        if searchOptions.contentTypes.contains(.note) {
            for note in appState.activeNotes {
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

        // Order by category section, most recent first within each. Keeping
        // the flat array in visual order keeps shift-click range selection sane.
        let grouped = Dictionary(grouping: results, by: \.contentType)
        return ContentType.searchable
            .compactMap { grouped[$0] }
            .flatMap { $0.sorted { $0.date > $1.date } }
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

    /// Rows visible per section before "Show all" kicks in.
    private static let sectionRowCap = 6

    private var groupedResults: [(type: ContentType, items: [UniversalSearchResult])] {
        let grouped = Dictionary(grouping: cachedSearchResults, by: \.contentType)
        return ContentType.searchable.compactMap { type in
            grouped[type].map { (type, $0) }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                let groups = groupedResults
                ForEach(groups, id: \.type) { group in
                    Section {
                        let items = visibleItems(for: group, isOnlySection: groups.count == 1)
                        ForEach(items) { result in
                            searchResultRow(result)
                        }

                        if items.count < group.items.count {
                            showAllButton(type: group.type, total: group.items.count)
                        }
                    } header: {
                        sectionHeader(type: group.type, count: group.items.count)
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.lg)
        }
    }

    private func visibleItems(
        for group: (type: ContentType, items: [UniversalSearchResult]),
        isOnlySection: Bool
    ) -> [UniversalSearchResult] {
        // Selection mode shows everything so shift-click ranges match what's visible.
        if isSelectionMode || isOnlySection || expandedSections.contains(group.type) {
            return group.items
        }
        return Array(group.items.prefix(Self.sectionRowCap))
    }

    private func sectionHeader(type: ContentType, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: type.iconName)
                .font(.system(size: 10))
                .foregroundStyle(type.color)

            Text(type.searchGroupName)
                .hudLabel()

            Text("\(count)")
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.tertiaryText)

            Rectangle()
                .fill(Theme.Colors.gridLine)
                .frame(height: 1)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.Colors.background)
    }

    private func showAllButton(type: ContentType, total: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                _ = expandedSections.insert(type)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("Show all \(total) \(type.searchGroupName.lowercased())")
                    .font(Theme.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.accentText)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func searchResultRow(_ result: UniversalSearchResult) -> some View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.xs) {
                    Text("Search Your Otto")
                        .font(Theme.Typography.title)

                    Text("Find anything across your library — or browse a category below.")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xxl)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Browse")
                        .hudLabel()
                        .padding(.horizontal, Theme.Spacing.xl)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.sm)],
                        spacing: Theme.Spacing.sm
                    ) {
                        ForEach(ContentType.searchable) { type in
                            categoryTile(type)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                }

                if !recentItems.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Recently updated")
                            .hudLabel()
                            .padding(.horizontal, Theme.Spacing.xl)

                        ForEach(recentItems) { result in
                            searchResultRow(result)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .onAppear {
            computeRecentItems()
        }
    }

    private func categoryTile(_ type: ContentType) -> some View {
        Button {
            searchOptions.contentTypes = [type]
            isSearchFieldFocused = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: type.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(type.color)
                    .frame(width: 30, height: 30)
                    .background(type.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(categoryCount(type).formatted())")
                        .font(Theme.Typography.monoBody)
                        .foregroundStyle(Theme.Colors.text)

                    Text(type.searchGroupName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
        .buttonStyle(.plain)
        .help("Browse \(type.searchGroupName)")
    }

    private func categoryCount(_ type: ContentType) -> Int {
        switch type {
        case .todo: return appState.todos.count
        case .note: return appState.activeNotes.count
        case .idea: return appState.ideas.count
        case .reminder: return appState.reminders.count
        case .bookmark: return appState.bookmarks.count
        case .meeting: return appState.meetings.count
        case .email: return appState.emails.count
        case .connection: return appState.connections.count
        case .file: return appState.files.count
        default: return 0
        }
    }

    /// Most recently touched items across the user's own content. Emails and
    /// connections are skipped — they sync in bulk and would drown the list.
    private func computeRecentItems() {
        var candidates: [UniversalSearchResult] = []
        candidates += appState.todos.filter { !$0.isCompleted }.map { .from($0) }
        candidates += appState.activeNotes.map { .from($0) }
        candidates += appState.ideas.filter { $0.status != .archived }.map { .from($0) }
        candidates += appState.reminders.filter { !$0.isCompleted }.map { .from($0) }
        candidates += appState.bookmarks.map { .from($0) }
        candidates += appState.meetings.map { .from($0) }
        candidates += appState.files.map { .from($0) }

        // Cap each type so one busy category can't fill every slot.
        var picked: [UniversalSearchResult] = []
        var perType: [ContentType: Int] = [:]
        for item in candidates.sorted(by: { $0.date > $1.date }) {
            guard picked.count < 8 else { break }
            if perType[item.contentType, default: 0] < 3 {
                perType[item.contentType, default: 0] += 1
                picked.append(item)
            }
        }
        recentItems = picked
    }

    // MARK: - Empty Search State

    private var emptySearchState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.sm) {
                Text("No results found")
                    .font(Theme.Typography.headline)

                if hasActiveFilters && searchText.isEmpty {
                    Text("No items match your current filters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                } else {
                    Text("Try a different search term or broaden your filters.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                if !searchOptions.includeContent && !searchText.isEmpty {
                    Button {
                        searchOptions.includeContent = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10))
                            Text("Search inside content")
                                .font(Theme.Typography.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.Colors.selectTint))
                        .overlay(Capsule().strokeBorder(Theme.Colors.accent.opacity(0.45), lineWidth: 1))
                        .foregroundStyle(Theme.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                }

                if hasActiveFilters {
                    Button {
                        clearAllFilters()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                            Text("Clear filters")
                                .font(Theme.Typography.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
                        .foregroundStyle(Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Locate Item

    private func locateItem(_ result: UniversalSearchResult) {
        appState.locate(type: result.contentType, id: result.id)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .frame(width: 700, height: 600)
}
