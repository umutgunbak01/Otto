import SwiftUI

/// Generic table for a user-defined custom tab. Columns come straight from
/// the tab's `CustomFieldDefinition`s; cells reuse the same `CustomFieldCell`
/// inline editors the Connections table uses for its custom columns.
struct CustomTabListView: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition

    @State private var searchText: String = ""
    /// Which (row, field) is currently in edit mode. Only one at a time.
    @State private var editingCell: EditingCell?
    @State private var hoveredRowId: UUID?
    @State private var showingTabEditor = false
    @State private var recordPendingDelete: CustomRecord?

    private struct EditingCell: Equatable {
        let recordId: UUID
        let fieldId: UUID
    }

    private let rowHeight: CGFloat = 36
    /// Trailing gutter that hosts the hover-delete button.
    private let gutterWidth: CGFloat = 44

    private var records: [CustomRecord] {
        var result = appState.customRecords.filter { $0.tabId == tab.id }
        if !searchText.isEmpty {
            result = result.filter {
                $0.searchableText(in: tab).localizedCaseInsensitiveContains(searchText)
            }
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    /// Column widths for the given viewport width. Base widths come from the
    /// field kinds; when their sum is narrower than the viewport they scale
    /// up proportionally so the table fills the content area edge to edge.
    /// Wider-than-viewport tables keep base widths and scroll horizontally.
    private func columnWidths(available: CGFloat) -> [UUID: CGFloat] {
        let fields = tab.sortedFields
        let base = fields.map { $0.kind.defaultColumnWidth }
        let baseTotal = base.reduce(0, +)
        guard baseTotal > 0 else { return [:] }
        let scale = max((available - gutterWidth) / baseTotal, 1)
        return Dictionary(uniqueKeysWithValues: zip(fields.map(\.id), base.map { $0 * scale }))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            OttoDivider()

            if records.isEmpty && searchText.isEmpty {
                emptyState
            } else if records.isEmpty {
                noResultsState
            } else {
                table
            }
        }
        .sheet(isPresented: $showingTabEditor) {
            CustomTabEditorSheet(existing: tab, onSave: nil)
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

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)

                Text(tab.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountBadge(count: records.count)

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
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Table

    private var table: some View {
        // GeometryReader feeds the viewport size so narrow tables stretch to
        // full width and short ones pin to the top instead of the two-axis
        // ScrollView's smaller-than-viewport centering.
        GeometryReader { geo in
            let widths = columnWidths(available: geo.size.width)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeaderRow(widths: widths)
                    OttoDivider()
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            recordRow(record, widths: widths)
                            OttoDivider()
                        }
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func width(_ field: CustomFieldDefinition, in widths: [UUID: CGFloat]) -> CGFloat {
        widths[field.id] ?? field.kind.defaultColumnWidth
    }

    private func columnHeaderRow(widths: [UUID: CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(tab.sortedFields) { field in
                HStack(spacing: 5) {
                    Image(systemName: field.kind.icon)
                        .font(.system(size: 9))
                    Text(field.name)
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.xwide)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, 8)
                .frame(width: width(field, in: widths), height: 32, alignment: .leading)
            }
            Color.clear
                .frame(width: gutterWidth, height: 32)
        }
        .background(Theme.Colors.bg1)
    }

    @ViewBuilder
    private func recordRow(_ record: CustomRecord, widths: [UUID: CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(tab.sortedFields) { field in
                CustomFieldCell(
                    definition: field,
                    value: record.values[field.id],
                    isEditing: editingCell == EditingCell(recordId: record.id, fieldId: field.id),
                    onBeginEdit: {
                        editingCell = EditingCell(recordId: record.id, fieldId: field.id)
                    },
                    onEndEdit: {
                        editingCell = nil
                    },
                    onCommit: { newValue in
                        Task { await appState.setCustomRecordValue(on: record.id, fieldId: field.id, value: newValue) }
                        editingCell = nil
                    }
                )
                .padding(.horizontal, 8)
                .frame(width: width(field, in: widths), height: rowHeight, alignment: .leading)
            }

            // Hover-only delete, pinned in the trailing gutter.
            Group {
                if hoveredRowId == record.id {
                    Button {
                        recordPendingDelete = record
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Delete record")
                    #endif
                }
            }
            .frame(width: gutterWidth, height: rowHeight)
        }
        .background(hoveredRowId == record.id ? Theme.Colors.hoverTint : Color.clear)
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                hoveredRowId = record.id
            } else if hoveredRowId == record.id {
                hoveredRowId = nil
            }
        }
        #endif
        .contextMenu {
            Button(role: .destructive) {
                recordPendingDelete = record
            } label: {
                Label("Delete record", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
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

    // MARK: - Actions

    /// Insert an empty row and drop straight into editing its title cell.
    private func addRecord() {
        let record = CustomRecord(tabId: tab.id)
        Task {
            await appState.addCustomRecord(record)
            if let primary = tab.primaryField {
                editingCell = EditingCell(recordId: record.id, fieldId: primary.id)
            }
        }
    }
}
