import SwiftUI

// MARK: - Compact value chip

/// Small read-only rendering of one custom field value — select chips keep
/// their option colors, checkboxes render as marks, URLs as their host.
/// Shared by list rows, gallery cards, and board cards.
struct CustomValueChip: View {
    let field: CustomFieldDefinition
    let value: CustomFieldValue

    var body: some View {
        switch value {
        case .optionIds(let ids):
            HStack(spacing: 3) {
                ForEach(ids.prefix(3), id: \.self) { id in
                    if let option = field.options.first(where: { $0.id == id }) {
                        optionChip(option)
                    }
                }
                if ids.count > 3 {
                    Text("+\(ids.count - 3)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        case .bool(let b):
            if b {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.square.fill").font(.system(size: 10))
                    Text(field.name).font(.system(size: 10.5))
                }
                .foregroundStyle(Theme.Colors.green)
            }
        case .date:
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 9))
                Text(value.displayString(for: field)).font(.system(size: 10.5))
            }
            .foregroundStyle(Theme.Colors.textDim)
        case .number:
            Text(value.displayString(for: field))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Colors.textDim)
        case .url(let raw):
            HStack(spacing: 3) {
                Image(systemName: "link").font(.system(size: 9))
                Text(host(raw)).font(.system(size: 10.5))
            }
            .foregroundStyle(Theme.Colors.accentText)
        case .text(let s):
            Text(s)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Colors.textDim)
                .lineLimit(1)
        }
    }

    private func optionChip(_ option: CustomFieldOption) -> some View {
        let color = Color.fromHex(option.colorHex) ?? Theme.Colors.accent
        return Text(option.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }

    private func host(_ raw: String) -> String {
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: withScheme), let host = url.host else { return raw }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - List layout

/// Compact checklist-style rows: leading checkbox (the tab's first checkbox
/// field, toggleable in place), title from the primary field, then the other
/// fields as trailing chips. Row click opens the record editor.
struct RecordListRows: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition
    let records: [CustomRecord]
    let onOpen: (CustomRecord) -> Void
    let onDelete: (CustomRecord) -> Void
    /// Full-bleed lists indent rows to the page gutter; embedded (dashboard
    /// records block) lists sit inside a card that already pads.
    var horizontalPadding: CGFloat = Theme.Spacing.lg

    @State private var hoveredRowId: UUID?

    private var checkboxField: CustomFieldDefinition? {
        tab.sortedFields.first { $0.kind == .checkbox }
    }

    /// Fields rendered as trailing chips: everything except the title field,
    /// the toggle checkbox, and long text (too big for a row).
    private var chipFields: [CustomFieldDefinition] {
        tab.sortedFields.dropFirst().filter { field in
            field.id != checkboxField?.id && field.kind != .longText
        }
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(records) { record in
                row(record)
                OttoDivider().padding(.leading, horizontalPadding)
            }
        }
    }

    private func row(_ record: CustomRecord) -> some View {
        let done = isDone(record)
        return HStack(spacing: Theme.Spacing.sm) {
            if let field = checkboxField {
                Button {
                    Task {
                        await appState.setCustomRecordValue(
                            on: record.id, fieldId: field.id,
                            value: done ? nil : .bool(true)
                        )
                    }
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(done ? Theme.Colors.green : Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            Text(record.displayTitle(in: tab))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(done ? Theme.Colors.textDim : Theme.Colors.text)
                .strikethrough(done, color: Theme.Colors.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            HStack(spacing: 8) {
                ForEach(chipFields.suffix(4)) { field in
                    if let value = record.values[field.id] {
                        CustomValueChip(field: field, value: value)
                    }
                }
            }

            if hoveredRowId == record.id {
                Button {
                    onDelete(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 38)
        .contentShape(Rectangle())
        .background(hoveredRowId == record.id ? Theme.Colors.hoverTint : Color.clear)
        .onTapGesture { onOpen(record) }
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

    private func isDone(_ record: CustomRecord) -> Bool {
        guard let field = checkboxField, let value = record.values[field.id],
              case .bool(let b) = value else { return false }
        return b
    }
}

// MARK: - Gallery layout

/// Card grid: title plus each non-empty field as a label/value row.
struct RecordGalleryGrid: View {
    let tab: CustomTabDefinition
    let records: [CustomRecord]
    let onOpen: (CustomRecord) -> Void
    let onDelete: (CustomRecord) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: Theme.Spacing.md)],
            alignment: .leading,
            spacing: Theme.Spacing.md
        ) {
            ForEach(records) { record in
                card(record)
            }
        }
    }

    private func card(_ record: CustomRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displayTitle(in: tab))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.text)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(tab.sortedFields.dropFirst().prefix(5)) { field in
                    if let value = record.values[field.id] {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(field.name.uppercased())
                                .font(.system(size: 8.5, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .frame(width: 74, alignment: .leading)
                            if field.kind == .longText {
                                Text(value.displayString(for: field))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.Colors.textDim)
                                    .lineLimit(2)
                            } else {
                                CustomValueChip(field: field, value: value)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .onTapGesture { onOpen(record) }
        .contextMenu {
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Delete record", systemImage: "trash")
            }
        }
    }
}
