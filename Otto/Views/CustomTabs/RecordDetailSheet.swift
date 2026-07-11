import SwiftUI

/// Full editor for one custom record — every field stacked as a form row,
/// reusing the same `CustomFieldCell` inline editors the table cells use.
/// Board / list / gallery / dashboard layouts open this on card click.
struct RecordDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let tab: CustomTabDefinition
    let recordId: UUID

    @State private var editingFieldId: UUID?
    @State private var showDeleteConfirm = false

    /// Live lookup so edits from the cells re-render immediately.
    private var record: CustomRecord? {
        appState.customRecords.first { $0.id == recordId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(tab.sortedFields) { field in
                            fieldRow(field, record: record)
                        }

                        Text("Added \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · Updated \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.top, 4)
                    }
                    .padding(16)
                }
            } else {
                Text("Record deleted")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            OttoDivider()
            footer
        }
        .frame(width: 440, height: 520)
        .background(Theme.Colors.bg2)
        .confirmationDialog(
            "Delete \"\(record.map { $0.displayTitle(in: tab) } ?? "record")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete record", role: .destructive) {
                if let record {
                    Task {
                        await appState.deleteCustomRecord(record)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.accentText)
            Text(record.map { $0.displayTitle(in: tab) } ?? tab.name)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(1)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fieldRow(_ field: CustomFieldDefinition, record: CustomRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: field.kind.icon)
                    .font(.system(size: 9))
                Text(field.name)
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .textCase(.uppercase)
            }
            .foregroundStyle(Theme.Colors.tertiaryText)

            CustomFieldCell(
                definition: field,
                value: record.values[field.id],
                isEditing: editingFieldId == field.id,
                onBeginEdit: { editingFieldId = field.id },
                onEndEdit: { editingFieldId = nil },
                onCommit: { newValue in
                    Task { await appState.setCustomRecordValue(on: record.id, fieldId: field.id, value: newValue) }
                    editingFieldId = nil
                }
            )
            .padding(.horizontal, 8)
            .frame(minHeight: 30, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(editingFieldId == field.id ? Theme.Colors.accent.opacity(0.5) : Theme.Colors.border, lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("Delete")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.red)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding(12)
    }
}
