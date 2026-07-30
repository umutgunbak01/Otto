import SwiftUI

/// Container for one user-defined custom tab: shared header (name, search,
/// actions) plus the layout-specific body — spreadsheet table, kanban board,
/// card gallery, compact list, or the agent-composed dashboard.
struct CustomTabView: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition

    @State private var searchText: String = ""
    @State private var showingTabEditor = false
    @State private var recordPendingDelete: CustomRecord?
    /// Record open in the detail sheet (board/list/gallery/dashboard flows).
    @State private var openRecordId: UUID?
    /// Freshly added record the table layout should drop into title editing.
    @State private var focusRecordId: UUID?
    /// Multi-collection tabs on a record layout show one collection at a
    /// time; header chips switch. nil / stale → first collection.
    @State private var activeCollectionId: UUID?

    /// The collection the non-dashboard layouts render.
    private var activeCollection: TabCollection? {
        if let id = activeCollectionId, let c = tab.collections.first(where: { $0.id == id }) {
            return c
        }
        return tab.sortedCollections.first
    }

    private var allTabRecords: [CustomRecord] {
        appState.customRecords
            .filter { $0.tabId == tab.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Active collection's records, search-filtered — what the record
    /// layouts render.
    private var records: [CustomRecord] {
        guard let collection = activeCollection else { return [] }
        var result = allTabRecords.filter { tab.collection(for: $0)?.id == collection.id }
        if !searchText.isEmpty {
            result = result.filter {
                $0.searchableText(in: tab).localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .sheet(isPresented: $showingTabEditor) {
            CustomTabEditorSheet(existing: tab, onSave: nil)
        }
        .sheet(isPresented: Binding(
            get: { openRecordId != nil },
            set: { if !$0 { openRecordId = nil } }
        )) {
            if let id = openRecordId {
                RecordDetailSheet(tab: tab, recordId: id)
            }
        }
        .confirmationDialog(
            "Delete \"\(recordPendingDelete.map { $0.displayTitle(in: tab) } ?? "record")\"?",
            isPresented: Binding(
                get: { recordPendingDelete != nil },
                set: { if !$0 { recordPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete record", role: .destructive) {
                if let record = recordPendingDelete {
                    Task { await appState.deleteCustomRecord(record) }
                }
                recordPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { recordPendingDelete = nil }
        }
    }

    // MARK: - Header

    private var showsRecordControls: Bool {
        !(tab.layout == .dashboard && tab.collections.allSatisfy { $0.fields.isEmpty })
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.name)
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Colors.text)
                    if let subtitle = tab.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                    }
                }

                if showsRecordControls {
                    OttoCountChip(text: recordCountText)
                }

                Spacer(minLength: 8)

                OttoBarButton(label: "Edit tab", systemImage: "slider.horizontal.3") {
                    showingTabEditor = true
                }

                if showsRecordControls, activeCollection?.fields.isEmpty == false {
                    OttoNewButton(label: "New record") { addRecord() }
                }
            }

            if tab.layout != .dashboard {
                HStack(spacing: Theme.Spacing.sm) {
                    OttoSearchMini(placeholder: "Search", text: $searchText, width: 220)

                    if tab.collections.count > 1 {
                        collectionChips
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var recordCountText: String {
        let n = allTabRecords.count
        return n == 1 ? "1 record" : "\(n) records"
    }

    /// One chip per collection — the record layouts show one at a time.
    private var collectionChips: some View {
        HStack(spacing: 4) {
            ForEach(tab.sortedCollections) { collection in
                let isActive = activeCollection?.id == collection.id
                let count = allTabRecords.filter { tab.collection(for: $0)?.id == collection.id }.count
                Button {
                    activeCollectionId = collection.id
                } label: {
                    HStack(spacing: 5) {
                        Text(collection.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isActive ? Theme.Colors.text : Theme.Colors.tertiaryText)
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(isActive ? Theme.Colors.panel2 : Color.clear)
                    )
                    .overlay(
                        Capsule().strokeBorder(isActive ? Theme.Colors.border : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Layout routing

    @ViewBuilder
    private var content: some View {
        if tab.layout == .dashboard {
            if tab.blocks.isEmpty {
                dashboardEmptyState
            } else {
                ScrollView {
                    TabBlocksColumn(
                        tab: tab,
                        onOpenRecord: { openRecordId = $0.id },
                        onDeleteRecord: { recordPendingDelete = $0 }
                    )
                    .padding(Theme.Spacing.lg)
                }
            }
        } else if let collection = activeCollection {
            recordsContent(collection)
        } else {
            emptyOrNoResults
        }
    }

    @ViewBuilder
    private func recordsContent(_ collection: TabCollection) -> some View {
        switch tab.layout {
        case .table:
            if records.isEmpty {
                emptyOrNoResults
            } else {
                CustomTabTableView(
                    tab: tab,
                    collection: collection,
                    records: records,
                    focusRecordId: $focusRecordId,
                    onDelete: { recordPendingDelete = $0 }
                )
            }

        case .board:
            if records.isEmpty {
                emptyOrNoResults
            } else {
                RecordBoardView(
                    tab: tab,
                    collection: collection,
                    records: records,
                    embedded: false,
                    onOpen: { openRecordId = $0.id },
                    onDelete: { recordPendingDelete = $0 },
                    onAddToColumn: { option in addRecord(presetOption: option) }
                )
            }

        case .list:
            if records.isEmpty {
                emptyOrNoResults
            } else {
                ScrollView {
                    RecordListRows(
                        tab: tab,
                        collection: collection,
                        records: records,
                        onOpen: { openRecordId = $0.id },
                        onDelete: { recordPendingDelete = $0 }
                    )
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }

        case .gallery:
            if records.isEmpty {
                emptyOrNoResults
            } else {
                ScrollView {
                    RecordGalleryGrid(
                        tab: tab,
                        collection: collection,
                        records: records,
                        onOpen: { openRecordId = $0.id },
                        onDelete: { recordPendingDelete = $0 }
                    )
                    .padding(Theme.Spacing.lg)
                }
            }

        case .calendar:
            // Calendar renders even with zero records — the month grid is
            // the empty state.
            ScrollView {
                RecordCalendarView(
                    tab: tab,
                    collection: collection,
                    records: records,
                    embedded: true,
                    onOpen: { openRecordId = $0.id },
                    onDelete: { recordPendingDelete = $0 }
                )
                .padding(Theme.Spacing.lg)
            }

        case .dashboard:
            EmptyView()
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyOrNoResults: some View {
        if searchText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: tab.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("No records yet")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                Text("Add rows here, or just ask Otto — it can fill this tab for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textDim)
                if activeCollection?.fields.isEmpty == false {
                    Button {
                        addRecord()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 11))
                            Text("New record").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("No matches for \"\(searchText)\"")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textDim)
                Button("Clear search") { searchText = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dashboardEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Text("Nothing on this dashboard yet")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.text)
            Text("Ask Otto to build it — e.g. \"add a summary, a progress bar and a standings table to my \(tab.name) tab\".")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Insert an empty row into the active collection. Table layout drops
    /// into inline title editing; every other layout opens the editor sheet.
    private func addRecord(presetOption: (field: CustomFieldDefinition, option: CustomFieldOption?)? = nil) {
        guard let collection = activeCollection else { return }
        var values: [UUID: CustomFieldValue] = [:]
        if let preset = presetOption, let option = preset.option {
            values[preset.field.id] = .optionIds([option.id])
        }
        let record = CustomRecord(tabId: tab.id, collectionId: collection.id, values: values)
        Task {
            await appState.addCustomRecord(record)
            if tab.layout == .table {
                focusRecordId = record.id
            } else {
                openRecordId = record.id
            }
        }
    }
}
