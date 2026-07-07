import SwiftUI

/// Popover content for the "Columns" button in the Connections filter bar.
/// Toggles visibility, reorders columns, and is the entry point for
/// creating / editing / deleting custom fields.
struct ConnectionColumnsMenu: View {
    @Environment(AppState.self) private var appState
    @Binding var layout: ColumnLayout
    @Binding var isPresented: Bool

    @State private var showCreateSheet: Bool = false
    @State private var editingFieldId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(orderedColumns, id: \.self) { column in
                        columnRow(column)
                    }
                }
                .padding(.vertical, 6)
            }
            OttoDivider()
            footer
        }
        .frame(width: 280, height: 420)
        .background(Theme.Colors.bg2)
        .sheet(isPresented: $showCreateSheet) {
            CustomFieldEditorSheet()
                .environment(appState)
        }
        .sheet(item: editingFieldBinding) { id in
            if let def = appState.connectionCustomFields.first(where: { $0.id == id.value }) {
                CustomFieldEditorSheet(existing: def)
                    .environment(appState)
            }
        }
    }

    // MARK: Derived

    /// All available columns in current display order:
    /// visible columns (in their current order) first, then any hidden
    /// columns appended at the end so the user can re-enable them.
    private var orderedColumns: [ConnectionColumn] {
        let available = ColumnLayout.availableColumns(definitions: appState.connectionCustomFields)
        let visibleSet = Set(layout.visible)
        let hidden = available.filter { !visibleSet.contains($0) }
        return layout.visible + hidden
    }

    private var editingFieldBinding: Binding<IdentifiedId?> {
        Binding(
            get: { editingFieldId.map { IdentifiedId(value: $0) } },
            set: { editingFieldId = $0?.value }
        )
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            Text("Columns")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.secondaryText)
            Spacer()
            Button {
                layout = .default
                ConnectionColumnLayoutStore.save(layout)
            } label: {
                Text("Reset")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Reset to the default columns")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Button {
            showCreateSheet = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill").font(.system(size: 12))
                Text("New custom field").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.Colors.accent)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Row

    @ViewBuilder
    private func columnRow(_ column: ConnectionColumn) -> some View {
        let isVisible = layout.visible.contains(column)
        let isCustom: Bool = {
            if case .custom = column { return true }
            return false
        }()
        HStack(spacing: 8) {
            Button {
                toggleVisibility(of: column)
            } label: {
                Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isVisible ? Theme.Colors.accent : Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)

            Image(systemName: ColumnLayout.icon(for: column, definitions: appState.connectionCustomFields))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 14)

            Text(ColumnLayout.label(for: column, definitions: appState.connectionCustomFields))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)

            Spacer()

            if isVisible {
                // Up / down reorder buttons. Drag-reorder inside a popover
                // is fiddly; explicit arrows keep this predictable.
                Button { moveColumn(column, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.tertiaryText)

                Button { moveColumn(column, by: +1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            if isCustom, case .custom(let id) = column {
                Menu {
                    Button("Edit") { editingFieldId = id }
                    Button("Delete", role: .destructive) {
                        Task { await appState.deleteCustomField(id: id) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: Mutations

    private func toggleVisibility(of column: ConnectionColumn) {
        if let index = layout.visible.firstIndex(of: column) {
            layout.visible.remove(at: index)
        } else {
            layout.visible.append(column)
        }
        ConnectionColumnLayoutStore.save(layout)
    }

    private func moveColumn(_ column: ConnectionColumn, by delta: Int) {
        guard let from = layout.visible.firstIndex(of: column) else { return }
        let to = max(0, min(layout.visible.count - 1, from + delta))
        guard from != to else { return }
        let item = layout.visible.remove(at: from)
        layout.visible.insert(item, at: to)
        ConnectionColumnLayoutStore.save(layout)
    }
}

/// Identifiable wrapper for UUID, used to drive `sheet(item:)` on the edit flow.
struct IdentifiedId: Identifiable, Hashable {
    let value: UUID
    var id: UUID { value }
}
