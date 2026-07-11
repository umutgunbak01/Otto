import SwiftUI

/// Spreadsheet body for a custom tab's `table` layout. Columns come straight
/// from the tab's `CustomFieldDefinition`s; cells reuse the same
/// `CustomFieldCell` inline editors the Connections table uses. Header,
/// search, and record lifecycle live in `CustomTabView` — this view just
/// renders the given (already filtered) records.
struct CustomTabTableView: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition
    let records: [CustomRecord]
    /// Set by the parent right after inserting a row — the table opens the
    /// title cell's inline editor and clears it.
    @Binding var focusRecordId: UUID?
    let onDelete: (CustomRecord) -> Void

    /// Which (row, field) is currently in edit mode. Only one at a time.
    @State private var editingCell: EditingCell?
    @State private var hoveredRowId: UUID?

    private struct EditingCell: Equatable {
        let recordId: UUID
        let fieldId: UUID
    }

    private let rowHeight: CGFloat = 36
    /// Trailing gutter that hosts the hover-delete button.
    private let gutterWidth: CGFloat = 44

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
        .onChange(of: focusRecordId) { _, newValue in
            guard let id = newValue, let primary = tab.primaryField else { return }
            editingCell = EditingCell(recordId: id, fieldId: primary.id)
            focusRecordId = nil
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
                        onDelete(record)
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
                onDelete(record)
            } label: {
                Label("Delete record", systemImage: "trash")
            }
        }
    }
}
