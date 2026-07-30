import SwiftUI
import UniformTypeIdentifiers

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .alphabetical
    @State private var filterTag: String? = nil
    @State private var filterCategory: ConnectionCategory? = nil
    @State private var filterCloseness: ConnectionCloseness? = nil
    @State private var isImporting: Bool = false
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var detailConnectionId: UUID?
    @State private var showColumnsMenu: Bool = false
    @State private var layout: ColumnLayout = ConnectionColumnLayoutStore.load()
    /// The column header currently being dragged to reorder, if any.
    @State private var draggingColumn: ConnectionColumn?
    /// Which (row, column) is currently in edit mode. Only one at a time.
    @State private var editingCell: EditingCell?
    /// Row currently under the pointer — drives the hover tint.
    @State private var hoveredRowId: UUID?

    private struct EditingCell: Equatable {
        let connectionId: UUID
        let column: ConnectionColumn
    }

    private let nameColumnWidth: CGFloat = 240
    private let rowHeight: CGFloat = 36

    enum SortOption: String, CaseIterable {
        case alphabetical = "A-Z"
        case company = "Company"
        case closeness = "Closeness"
        case category = "Category"
        case connectionDate = "Date Added"
        case lastContact = "Last Contact"

        var description: String {
            switch self {
            case .alphabetical:   return "Sort alphabetically by name"
            case .company:        return "Sort by company name"
            case .closeness:      return "Sort by closeness"
            case .category:       return "Sort by category"
            case .connectionDate: return "Sort by connection date"
            case .lastContact:    return "Sort by last contact"
            }
        }
    }

    var allTags: [String] {
        Array(Set(appState.connections.flatMap { $0.tags })).sorted()
    }

    var filteredConnections: [Connection] {
        var result = appState.connections

        if !searchText.isEmpty {
            result = result.filter { connection in
                connection.fullName.localizedCaseInsensitiveContains(searchText) ||
                connection.company.localizedCaseInsensitiveContains(searchText) ||
                connection.headline.localizedCaseInsensitiveContains(searchText) ||
                connection.location.localizedCaseInsensitiveContains(searchText) ||
                connection.notes.localizedCaseInsensitiveContains(searchText) ||
                connection.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }

        if let tag = filterTag {
            result = result.filter { $0.tags.contains(tag) }
        }

        if let category = filterCategory {
            result = result.filter { $0.category == category }
        }

        if let closeness = filterCloseness {
            result = result.filter { $0.closeness == closeness }
        }

        switch sortOption {
        case .alphabetical:
            result.sort { $0.fullName.lowercased() < $1.fullName.lowercased() }
        case .company:
            result.sort {
                if $0.company.isEmpty && $1.company.isEmpty {
                    return $0.fullName.lowercased() < $1.fullName.lowercased()
                }
                if $0.company.isEmpty { return false }
                if $1.company.isEmpty { return true }
                return $0.company.lowercased() < $1.company.lowercased()
            }
        case .closeness:
            result.sort { closenessRank($0.closeness) > closenessRank($1.closeness) }
        case .category:
            result.sort { $0.category.label.lowercased() < $1.category.label.lowercased() }
        case .connectionDate:
            result.sort {
                let date0 = $0.connectionDate ?? Date.distantPast
                let date1 = $1.connectionDate ?? Date.distantPast
                return date0 > date1
            }
        case .lastContact:
            result.sort {
                let date0 = $0.lastContactedAt ?? Date.distantPast
                let date1 = $1.lastContactedAt ?? Date.distantPast
                return date0 > date1
            }
        }

        return result
    }

    private func closenessRank(_ c: ConnectionCloseness) -> Int {
        switch c {
        case .close: return 3
        case .friendly: return 2
        case .acquaintance: return 1
        case .unknown: return 0
        }
    }

    /// Sum of name column + every visible column width — fixes the inner
    /// VStack width so the outer ScrollView gets a horizontal scroll bar.
    private var totalTableWidth: CGFloat {
        nameColumnWidth + layout.visible.reduce(0) { acc, column in
            acc + layout.width(for: column, definitions: appState.connectionCustomFields)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            statChipsRow

            if filteredConnections.isEmpty && appState.connections.isEmpty {
                emptyState
            } else if filteredConnections.isEmpty {
                noResultsState
            } else {
                table
            }
        }
        .sheet(item: sheetBinding) { connection in
            connectionDetailSheet(for: connection)
        }
        .onChange(of: appState.locateItemId) { _, newValue in
            if let itemId = newValue,
               appState.connections.contains(where: { $0.id == itemId }) {
                detailConnectionId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.connections.contains(where: { $0.id == itemId }) {
                detailConnectionId = itemId
                appState.locateItemId = nil
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Table

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                columnHeaderRow
                OttoDivider()
                LazyVStack(spacing: 0) {
                    ForEach(filteredConnections) { connection in
                        connectionRow(connection)
                        OttoDivider(color: Color.white.opacity(0.038))
                    }
                }
            }
            .frame(width: totalTableWidth, alignment: .leading)
        }
        // Inset "sheet" container (mockup .sheetwrap): faint wash, rounded
        // hairline frame, floated off the pane edges.
        .background(Color.white.opacity(0.008))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            // Name column header (always present)
            HStack(spacing: 8) {
                if isSelectionMode {
                    Button {
                        if selectedConnectionIds.count == filteredConnections.count {
                            selectedConnectionIds.removeAll()
                        } else {
                            selectedConnectionIds = Set(filteredConnections.map { $0.id })
                        }
                    } label: {
                        Image(systemName: selectedConnectionIds.count == filteredConnections.count && !filteredConnections.isEmpty
                              ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
                Text("Name")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: nameColumnWidth, height: 32, alignment: .leading)

            // Visible columns. Padding lives INSIDE the frame so the frame
            // width equals the column-budget width — keeps totalTableWidth
            // and the ScrollView's content extent in sync.
            ForEach(layout.visible, id: \.self) { column in
                Text(ColumnLayout.label(for: column, definitions: appState.connectionCustomFields))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.horizontal, 8)
                    .frame(
                        width: layout.width(for: column, definitions: appState.connectionCustomFields),
                        height: 32,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    // Drag a column header to reorder; the data cells follow
                    // because every row iterates the same `layout.visible`.
                    .opacity(draggingColumn == column ? 0.35 : 1)
                    .onDrag {
                        draggingColumn = column
                        return NSItemProvider(object: column.storageKey as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: ColumnReorderDropDelegate(
                            target: column,
                            layout: $layout,
                            dragging: $draggingColumn
                        )
                    )
                    #if os(macOS)
                    .help("Drag to reorder")
                    #endif
            }
        }
        .background(Theme.Colors.bgRaised)
        // Catch-all so a drop on the pinned Name column or a gap still
        // finalizes the reorder (persist + clear the drag state).
        .onDrop(
            of: [.text],
            delegate: ColumnReorderFinalizeDelegate(layout: $layout, dragging: $draggingColumn)
        )
    }

    @ViewBuilder
    private func connectionRow(_ connection: Connection) -> some View {
        let isSelected = selectedConnectionIds.contains(connection.id)
        HStack(spacing: 0) {
            // Name cell (pinned visually but inside the same horizontal scroll)
            HStack(spacing: 8) {
                if isSelectionMode {
                    Button {
                        if isSelected {
                            selectedConnectionIds.remove(connection.id)
                        } else {
                            selectedConnectionIds.insert(connection.id)
                        }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    if isSelectionMode {
                        if isSelected {
                            selectedConnectionIds.remove(connection.id)
                        } else {
                            selectedConnectionIds.insert(connection.id)
                        }
                    } else {
                        detailConnectionId = connection.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        OttoAvatar(name: connection.fullName, size: 24)
                        Text(connection.fullName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(width: nameColumnWidth, height: rowHeight, alignment: .leading)

            ForEach(layout.visible, id: \.self) { column in
                ConnectionCell(
                    column: column,
                    connection: connection,
                    isEditing: editingCell == EditingCell(connectionId: connection.id, column: column),
                    onBeginEdit: {
                        editingCell = EditingCell(connectionId: connection.id, column: column)
                    },
                    onEndEdit: {
                        editingCell = nil
                    }
                )
                .padding(.horizontal, 8)
                .frame(
                    width: layout.width(for: column, definitions: appState.connectionCustomFields),
                    height: rowHeight,
                    alignment: .leading
                )
            }
        }
        .background(hoveredRowId == connection.id ? Color.white.opacity(0.018) : Color.clear)
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                hoveredRowId = connection.id
            } else if hoveredRowId == connection.id {
                hoveredRowId = nil
            }
        }
        #endif
    }


    // MARK: - Sheet binding

    private var sheetBinding: Binding<SheetConnection?> {
        Binding(
            get: {
                guard let id = detailConnectionId,
                      appState.connections.contains(where: { $0.id == id }) else { return nil }
                return SheetConnection(id: id)
            },
            set: { newValue in
                detailConnectionId = newValue?.id
            }
        )
    }

    private struct SheetConnection: Identifiable {
        let id: UUID
    }

    @ViewBuilder
    private func connectionDetailSheet(for sheet: SheetConnection) -> some View {
        if let connection = appState.connections.first(where: { $0.id == sheet.id }) {
            ZStack(alignment: .topTrailing) {
                ConnectionDetailView(
                    connection: connection,
                    onClose: { detailConnectionId = nil }
                )

                Button {
                    detailConnectionId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(minWidth: 560, minHeight: 640)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Title row (mockup .viewbar): serif display title + mono count chip.
            HStack(alignment: .center, spacing: 10) {
                Text("LinkedIn")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountChip(text: "\(filteredConnections.count) connections")

                Spacer(minLength: 8)

                if appState.isLoadingConnections {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                }

                if isSelectionMode && !selectedConnectionIds.isEmpty {
                    Button {
                        Task {
                            await appState.deleteConnections(Array(selectedConnectionIds))
                            selectedConnectionIds.removeAll()
                            isSelectionMode = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 10, weight: .bold))
                            Text("Delete (\(selectedConnectionIds.count))").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.Colors.bg0)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.red))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                OttoBarButton(label: isSelectionMode ? "Cancel" : "Select") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode { selectedConnectionIds.removeAll() }
                    }
                }
            }

            // Controls row: bordered menu buttons + mini search + primary CTA.
            HStack(spacing: Theme.Spacing.sm) {
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: "Sort: \(sortOption.rawValue)", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                Menu {
                    Button {
                        filterCloseness = nil
                    } label: {
                        HStack {
                            Text("All")
                            if filterCloseness == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(ConnectionCloseness.allCases, id: \.self) { c in
                        Button {
                            filterCloseness = c
                        } label: {
                            HStack {
                                Image(systemName: c.icon)
                                Text(c.label)
                                if filterCloseness == c { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: filterCloseness?.label ?? "Closeness", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                Menu {
                    Button {
                        filterCategory = nil
                    } label: {
                        HStack {
                            Text("All")
                            if filterCategory == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(ConnectionCategory.allCases, id: \.self) { cat in
                        Button {
                            filterCategory = cat
                        } label: {
                            HStack {
                                Image(systemName: cat.icon)
                                Text(cat.label)
                                if filterCategory == cat { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: filterCategory?.label ?? "Category", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                if !allTags.isEmpty {
                    Menu {
                        Button {
                            filterTag = nil
                        } label: {
                            HStack {
                                Text("All Tags")
                                if filterTag == nil { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(allTags, id: \.self) { tag in
                            Button {
                                filterTag = tag
                            } label: {
                                HStack {
                                    Text(tag)
                                    if filterTag == tag { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        OttoBarButtonLabel(label: filterTag ?? "Tags", showsCaret: true)
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    #endif
                }

                // Columns popover trigger — entry point for visibility, reorder, and custom-field creation.
                OttoBarButton(label: "Columns", showsCaret: true) {
                    showColumnsMenu.toggle()
                }
                .popover(isPresented: $showColumnsMenu) {
                    ConnectionColumnsMenu(layout: $layout, isPresented: $showColumnsMenu)
                        .environment(appState)
                }

                Spacer(minLength: 8)

                OttoSearchMini(placeholder: "Search", text: $searchText)

                OttoNewButton(label: "Import CSV", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            }

            if let error = appState.connectionImportError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.amber)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer()
                }
                .padding(6)
                .background(Theme.Colors.amber.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Closeness stat chips

    /// Distribution of the whole book (not the filtered slice) — four mono
    /// capsules under the viewbar. Chips with a zero count are skipped.
    private var closenessCounts: (close: Int, friendly: Int, light: Int, unknown: Int) {
        var close = 0, friendly = 0, light = 0, unknown = 0
        for connection in appState.connections {
            switch connection.closeness {
            case .close:        close += 1
            case .friendly:     friendly += 1
            case .acquaintance: light += 1
            case .unknown:      unknown += 1
            }
        }
        return (close, friendly, light, unknown)
    }

    @ViewBuilder
    private var statChipsRow: some View {
        let counts = closenessCounts
        if counts.close + counts.friendly + counts.light + counts.unknown > 0 {
            HStack(spacing: 6) {
                if counts.close > 0 {
                    statChip("\(counts.close) close friends", color: Theme.Colors.green, tint: Theme.Colors.tintGreen)
                }
                if counts.friendly > 0 {
                    statChip("\(counts.friendly) connections", color: Theme.Colors.accentText, tint: Theme.Colors.tintTeal)
                }
                if counts.light > 0 {
                    statChip("\(counts.light) light", color: Theme.Colors.amber, tint: Theme.Colors.tintAmber)
                }
                if counts.unknown > 0 {
                    statChip("\(counts.unknown) unknown", color: Theme.Colors.tertiaryText, tint: Theme.Colors.panel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, 12)
        }
    }

    private func statChip(_ text: String, color: Color, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(tint))
            .overlay(Capsule().strokeBorder(color.opacity(0.2), lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))

            Text("No connections")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Button {
                isImporting = true
            } label: {
                Text("Import CSV")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))

            Text("No results")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Button {
                searchText = ""
                filterTag = nil
                filterCategory = nil
                filterCloseness = nil
            } label: {
                Text("Clear filters")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await appState.importConnectionsFromCSV(url: url)
                } catch {
                    // Error is handled in AppState
                }
            }
        case .failure(let error):
            print("File import error: \(error)")
        }
    }
}

/// Avatar tint rotation — pairs of (background tint, initials color) cycled
/// deterministically per person, matching the mockup's .fava a1–a5 classes.
enum ConnectionAvatarPalette {
    static let pairs: [(bg: Color, fg: Color)] = [
        (Theme.Colors.tintViolet, Theme.Colors.violet),
        (Theme.Colors.tintGreen, Theme.Colors.green),
        (Theme.Colors.selectTint, Theme.Colors.accentText),
        (Theme.Colors.tintAmber, Theme.Colors.amber),
        (Theme.Colors.tintRed, Theme.Colors.red),
    ]

    /// Stable across launches: derived from the name's scalar sum, not
    /// `hashValue` (which is seeded per-process).
    static func colors(for connection: Connection) -> (bg: Color, fg: Color) {
        let sum = connection.fullName.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return pairs[sum % pairs.count]
    }
}

/// Drop delegate that reorders `layout.visible` as a column header is dragged
/// over another. Reordering happens live in `dropEntered` (so the table
/// animates as you drag), and the new order is persisted once on drop.
private struct ColumnReorderDropDelegate: DropDelegate {
    let target: ConnectionColumn
    @Binding var layout: ColumnLayout
    @Binding var dragging: ConnectionColumn?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = layout.visible.firstIndex(of: dragging),
              let to = layout.visible.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            layout.visible.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        ConnectionColumnLayoutStore.save(layout)
        return true
    }

    /// If the drag ends outside any header (no drop), clear the drag state so
    /// the faded column snaps back to normal.
    func dropExited(info: DropInfo) {}
}

/// Fallback drop target for the whole header row: finalizes a reorder when the
/// drop lands somewhere other than a specific column header (the pinned Name
/// cell, padding, or a gap). The live reordering already happened in the
/// per-column `ColumnReorderDropDelegate`, so this just persists + resets.
private struct ColumnReorderFinalizeDelegate: DropDelegate {
    @Binding var layout: ColumnLayout
    @Binding var dragging: ConnectionColumn?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        ConnectionColumnLayoutStore.save(layout)
        return true
    }
}

#Preview {
    ConnectionListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
