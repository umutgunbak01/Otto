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

    enum SortOption: String, CaseIterable {
        case alphabetical = "A-Z"
        case company = "Company"
        case closeness = "Closeness"
        case category = "Category"
        case connectionDate = "Date Added"

        var description: String {
            switch self {
            case .alphabetical: return "Sort alphabetically by name"
            case .company: return "Sort by company name"
            case .closeness: return "Sort by closeness"
            case .category: return "Sort by category"
            case .connectionDate: return "Sort by connection date"
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

    var body: some View {
        VStack(spacing: 0) {
            header

            OttoDivider()

            // Column header row
            columnHeader

            OttoDivider()

            // List content
            if filteredConnections.isEmpty && appState.connections.isEmpty {
                emptyState
            } else if filteredConnections.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConnections) { connection in
                            ConnectionRow(
                                connection: connection,
                                isSelectionMode: isSelectionMode,
                                isSelected: selectedConnectionIds.contains(connection.id),
                                onToggleSelection: {
                                    if selectedConnectionIds.contains(connection.id) {
                                        selectedConnectionIds.remove(connection.id)
                                    } else {
                                        selectedConnectionIds.insert(connection.id)
                                    }
                                },
                                onOpen: { detailConnectionId = connection.id },
                                onUpdateCloseness: { tier in
                                    var updated = connection
                                    updated.closeness = tier
                                    Task { await appState.updateConnection(updated) }
                                },
                                onUpdateCategory: { cat in
                                    var updated = connection
                                    updated.category = cat
                                    Task { await appState.updateConnection(updated) }
                                }
                            )
                            OttoDivider()
                        }
                    }
                }
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
            HStack(alignment: .center) {
                Text("⌬ CONNECTIONS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filteredConnections.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

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
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Delete (\(selectedConnectionIds.count))")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.Colors.bg0)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.Colors.priorityUrgent)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode { selectedConnectionIds.removeAll() }
                    }
                } label: {
                    Text(isSelectionMode ? "Cancel" : "Select")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelectionMode ? Theme.Colors.secondaryText : Theme.Colors.accent)
                }
                .buttonStyle(.plain)

                Button {
                    isImporting = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text("Import CSV")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Spacing.sm) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.Colors.hoverTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .frame(maxWidth: 280)

                // Sort picker
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
                    filterChipLabel(icon: "arrow.up.arrow.down", text: sortOption.rawValue, isActive: false)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Closeness filter
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
                    filterChipLabel(
                        icon: "heart.circle",
                        text: filterCloseness?.label ?? "Closeness",
                        isActive: filterCloseness != nil
                    )
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Category filter
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
                    filterChipLabel(
                        icon: "square.grid.2x2",
                        text: filterCategory?.label ?? "Category",
                        isActive: filterCategory != nil
                    )
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                // Tag filter
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
                        filterChipLabel(
                            icon: "tag",
                            text: filterTag ?? "Tags",
                            isActive: filterTag != nil
                        )
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    #endif
                }

                Spacer()
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
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    private func filterChipLabel(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Theme.Colors.accent.opacity(0.1) : Theme.Colors.borderSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
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
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.accent)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }

            Text("Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Closeness")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 150, alignment: .leading)

            Text("Category")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, 8)
        .background(Theme.Colors.borderSubtle.opacity(0.5))
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

// MARK: - Connection Row (with neon hover)

private struct ConnectionRow: View {
    let connection: Connection
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onUpdateCloseness: (ConnectionCloseness) -> Void
    let onUpdateCategory: (ConnectionCategory) -> Void

    @State private var isHovered: Bool = false

    /// Neon accent color — tinted by the connection's category (falls back to the content-type accent)
    private var neonColor: Color {
        connection.category == .unknown ? ContentType.connection.color : connection.category.color
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isSelectionMode {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }

            Button {
                if isSelectionMode {
                    onToggleSelection()
                } else {
                    onOpen()
                }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    ZStack {
                        Circle()
                            .fill(ContentType.connection.color.opacity(isHovered ? 0.22 : 0.12))
                            .frame(width: 30, height: 30)
                            .shadow(
                                color: neonColor.opacity(isHovered ? 0.7 : 0),
                                radius: isHovered ? 8 : 0
                            )

                        Text(connection.initials)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ContentType.connection.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.fullName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHovered ? neonColor : Theme.Colors.text)
                            .lineLimit(1)

                        if !connection.headline.isEmpty || !connection.company.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            closenessMenu
                .frame(width: 150, alignment: .leading)

            categoryMenu
                .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, 8)
        .background(
            ZStack {
                // Neon glow fill
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(neonColor.opacity(isHovered ? 0.10 : 0))

                // Neon border
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(neonColor.opacity(isHovered ? 0.65 : 0), lineWidth: 1)
            }
            .padding(.horizontal, Theme.Spacing.md)
        )
        .shadow(color: neonColor.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 10 : 0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var subtitle: String {
        if !connection.headline.isEmpty && !connection.company.isEmpty {
            return "\(connection.headline) @ \(connection.company)"
        } else if !connection.headline.isEmpty {
            return connection.headline
        } else {
            return connection.company
        }
    }

    private var closenessMenu: some View {
        Menu {
            ForEach(ConnectionCloseness.allCases, id: \.self) { tier in
                Button {
                    onUpdateCloseness(tier)
                } label: {
                    HStack {
                        Image(systemName: tier.icon)
                        Text(tier.label)
                        if connection.closeness == tier {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connection.closeness.icon)
                    .font(.system(size: 11))
                Text(connection.closeness.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(connection.closeness == .unknown ? Theme.Colors.tertiaryText : connection.closeness.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(connection.closeness == .unknown ? Theme.Colors.hoverTint : connection.closeness.color.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(ConnectionCategory.allCases, id: \.self) { cat in
                Button {
                    onUpdateCategory(cat)
                } label: {
                    HStack {
                        Image(systemName: cat.icon)
                        Text(cat.label)
                        if connection.category == cat {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connection.category.icon)
                    .font(.system(size: 11))
                Text(connection.category.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(connection.category == .unknown ? Theme.Colors.tertiaryText : connection.category.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(connection.category == .unknown ? Theme.Colors.hoverTint : connection.category.color.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

#Preview {
    ConnectionListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
