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

    private var allRecords: [CustomRecord] {
        appState.customRecords
            .filter { $0.tabId == tab.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var records: [CustomRecord] {
        guard !searchText.isEmpty else { return allRecords }
        return allRecords.filter {
            $0.searchableText(in: tab).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
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
        !(tab.layout == .dashboard && tab.fields.isEmpty)
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.name)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.text)
                    if let subtitle = tab.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                    }
                }

                if showsRecordControls {
                    OttoCountBadge(count: allRecords.count)
                }

                Spacer()

                Button {
                    showingTabEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text("Edit tab").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.Colors.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if showsRecordControls && !tab.fields.isEmpty {
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

            if tab.layout != .dashboard {
                HStack(spacing: Theme.Spacing.sm) {
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
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .frame(maxWidth: 280)

                    Spacer()
                }
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Layout routing

    @ViewBuilder
    private var content: some View {
        switch tab.layout {
        case .dashboard:
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

        case .table:
            if records.isEmpty {
                emptyOrNoResults
            } else {
                CustomTabTableView(
                    tab: tab,
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
                        records: records,
                        onOpen: { openRecordId = $0.id },
                        onDelete: { recordPendingDelete = $0 }
                    )
                    .padding(Theme.Spacing.lg)
                }
            }
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
                if !tab.fields.isEmpty {
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

    /// Insert an empty row. Table layout drops into inline title editing;
    /// every other layout opens the record editor sheet.
    private func addRecord(presetOption: (field: CustomFieldDefinition, option: CustomFieldOption?)? = nil) {
        var values: [UUID: CustomFieldValue] = [:]
        if let preset = presetOption, let option = preset.option {
            values[preset.field.id] = .optionIds([option.id])
        }
        let record = CustomRecord(tabId: tab.id, values: values)
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
