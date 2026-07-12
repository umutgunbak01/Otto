import SwiftUI
import UniformTypeIdentifiers

/// Kanban board over a custom tab's records, grouped by a single-select
/// field (`collection.boardGroupField`). Cards drag between columns to change that
/// field; each column can spawn a pre-tagged record.
///
/// Two hosting modes: as the tab's full layout (`embedded == false`) each
/// column scrolls vertically within the fixed board height; embedded inside
/// a dashboard `records` block the columns render at natural height and the
/// page scrolls instead.
struct RecordBoardView: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition
    let collection: TabCollection
    let records: [CustomRecord]
    let embedded: Bool
    let onOpen: (CustomRecord) -> Void
    let onDelete: (CustomRecord) -> Void
    /// nil option = the "No <field>" column's add button.
    var onAddToColumn: ((field: CustomFieldDefinition, option: CustomFieldOption?)) -> Void = { _ in }

    @State private var dropTargetOptionId: UUID??  // nil = not targeting; .some(nil) = the "none" column

    private let columnWidth: CGFloat = 252

    private struct Column: Identifiable {
        let option: CustomFieldOption?   // nil = ungrouped
        let records: [CustomRecord]
        var id: String { option?.id.uuidString ?? "none" }
    }

    private func columns(for field: CustomFieldDefinition) -> [Column] {
        var byOption: [UUID: [CustomRecord]] = [:]
        var ungrouped: [CustomRecord] = []
        for record in records {
            if case .optionIds(let ids)? = record.values[field.id],
               let first = ids.first(where: { id in field.options.contains { $0.id == id } }) {
                byOption[first, default: []].append(record)
            } else {
                ungrouped.append(record)
            }
        }
        var out = field.options.map { Column(option: $0, records: byOption[$0.id] ?? []) }
        // Ungrouped column only when something is actually ungrouped — a
        // fully triaged board stays clean.
        if !ungrouped.isEmpty {
            out.append(Column(option: nil, records: ungrouped))
        }
        return out
    }

    var body: some View {
        if let field = collection.boardGroupField {
            board(field: field)
        } else {
            VStack(spacing: 8) {
                Text("Board layout needs a single-select column to group by.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.textDim)
                Text("Add one in Edit tab (e.g. Status: To do / In progress / Done).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity)
            .padding(Theme.Spacing.lg)
        }
    }

    private func board(field: CustomFieldDefinition) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ForEach(columns(for: field)) { column in
                    boardColumn(column, field: field)
                }
            }
            .padding(embedded ? 0 : Theme.Spacing.lg)
        }
        .frame(maxHeight: embedded ? nil : .infinity, alignment: .top)
    }

    private func boardColumn(_ column: Column, field: CustomFieldDefinition) -> some View {
        let color = column.option.flatMap { Color.fromHex($0.colorHex) } ?? Theme.Colors.tertiaryText
        let isTarget = dropTargetOptionId == .some(column.option?.id)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(column.option?.label ?? "No \(field.name)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text("\(column.records.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
                Button {
                    onAddToColumn((field: field, option: column.option))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Add record here")
                #endif
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Group {
                if embedded {
                    LazyVStack(spacing: Theme.Spacing.sm) {
                        columnCards(column, field: field)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: Theme.Spacing.sm) {
                            columnCards(column, field: field)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .frame(width: columnWidth, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.bg1.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isTarget ? Theme.Colors.accent.opacity(0.7) : Theme.Colors.border, lineWidth: 1)
        )
        .onDrop(of: [.plainText], isTargeted: Binding(
            get: { isTarget },
            set: { targeting in
                if targeting {
                    dropTargetOptionId = .some(column.option?.id)
                } else if isTarget {
                    dropTargetOptionId = nil
                }
            }
        )) { providers in
            handleDrop(providers, field: field, option: column.option)
        }
    }

    @ViewBuilder
    private func columnCards(_ column: Column, field: CustomFieldDefinition) -> some View {
        ForEach(column.records) { record in
            boardCard(record, groupField: field)
        }
        if column.records.isEmpty {
            Text("Drop cards here")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    private func boardCard(_ record: CustomRecord, groupField: CustomFieldDefinition) -> some View {
        // Up to 3 secondary fields, skipping the grouping column (the column
        // header already says it) and long text.
        let metaFields = collection.sortedFields.dropFirst()
            .filter { $0.id != groupField.id && $0.kind != .longText && record.values[$0.id] != nil }
            .prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            Text(record.displayTitle(in: tab))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !metaFields.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(metaFields)) { field in
                        if let value = record.values[field.id] {
                            CustomValueChip(field: field, value: value)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .onTapGesture { onOpen(record) }
        .onDrag { NSItemProvider(object: record.id.uuidString as NSString) }
        .contextMenu {
            ForEach(groupField.options) { option in
                Button {
                    setGroup(recordId: record.id, field: groupField, option: option)
                } label: {
                    Label(option.label, systemImage: "arrow.right.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Delete record", systemImage: "trash")
            }
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider], field: CustomFieldDefinition, option: CustomFieldOption?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String, let id = UUID(uuidString: idString) else { return }
            Task { @MainActor in
                guard appState.customRecords.contains(where: { $0.id == id && $0.tabId == tab.id }) else { return }
                setGroup(recordId: id, field: field, option: option)
            }
        }
        return true
    }

    private func setGroup(recordId: UUID, field: CustomFieldDefinition, option: CustomFieldOption?) {
        Task {
            await appState.setCustomRecordValue(
                on: recordId,
                fieldId: field.id,
                value: option.map { .optionIds([$0.id]) }
            )
        }
    }
}
