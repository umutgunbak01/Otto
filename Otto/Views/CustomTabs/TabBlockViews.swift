import SwiftUI

// MARK: - Dashboard blocks column

/// Vertical stack of a tab's agent-composed blocks — the body of the
/// `dashboard` layout. Each block gets a context menu for reordering and
/// removal; content edits flow through chat (the agent owns the blocks).
struct TabBlocksColumn: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition
    let onOpenRecord: (CustomRecord) -> Void
    let onDeleteRecord: (CustomRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(Array(tab.blocks.enumerated()), id: \.element.id) { index, block in
                TabBlockView(
                    tab: tab,
                    block: block,
                    onOpenRecord: onOpenRecord,
                    onDeleteRecord: onDeleteRecord
                )
                .contextMenu {
                    Button {
                        Task { await appState.moveCustomTabBlock(tabId: tab.id, blockId: block.id, up: true) }
                    } label: {
                        Label("Move up", systemImage: "arrow.up")
                    }
                    .disabled(index == 0)
                    Button {
                        Task { await appState.moveCustomTabBlock(tabId: tab.id, blockId: block.id, up: false) }
                    } label: {
                        Label("Move down", systemImage: "arrow.down")
                    }
                    .disabled(index == tab.blocks.count - 1)
                    Divider()
                    Button(role: .destructive) {
                        Task { await appState.removeCustomTabBlock(tabId: tab.id, blockId: block.id) }
                    } label: {
                        Label("Remove block", systemImage: "trash")
                    }
                }
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One block

struct TabBlockView: View {
    @Environment(AppState.self) private var appState
    let tab: CustomTabDefinition
    let block: TabBlock
    let onOpenRecord: (CustomRecord) -> Void
    let onDeleteRecord: (CustomRecord) -> Void

    var body: some View {
        switch TabBlockContent.parse(block: block) {
        case .viz(let spec):
            // The visualization card carries its own chrome + title header —
            // same rendering as chat `visualize` cards.
            VisualizationCard(spec: spec, embedded: true)
        case .markdown(let content):
            blockCard {
                MarkdownText(content, font: .system(size: 12.5), color: Theme.Colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .progress(let items):
            blockCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items.indices, id: \.self) { i in
                        progressRow(items[i])
                    }
                }
            }
        case .list(let style, let items):
            blockCard {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items.indices, id: \.self) { i in
                        listRow(style: style, item: items[i], displayIndex: i)
                    }
                }
            }
        case .timeline(let items):
            blockCard {
                timeline(items)
            }
        case .records(let config):
            recordsBlock(config)
        case nil:
            blockCard {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text("Block '\(block.id)' (\(block.typeName)) failed to render — ask Otto to rebuild it.")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    // MARK: Card chrome

    @ViewBuilder
    private func blockCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let title = block.title {
                Text(title.uppercased())
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: Progress

    private func progressRow(_ item: TabBlockContent.ProgressItem) -> some View {
        let fraction = min(max(item.value / item.target, 0), 1)
        let color = Color.fromHex(TabBlockColor.hex(for: item.color)) ?? Theme.Colors.accent
        let valueText = item.target == 100
            ? "\(Self.compact(item.value))%"
            : "\(Self.compact(item.value)) / \(Self.compact(item.target))"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.bg1)
                    Capsule()
                        .fill(color)
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0))
                }
            }
            .frame(height: 7)
            if let detail = item.detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private static func compact(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: List

    @ViewBuilder
    private func listRow(style: TabBlockContent.ListStyle, item: TabBlockContent.ListItem, displayIndex: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch style {
            case .check:
                Button {
                    Task {
                        await appState.setCustomTabBlockItemDone(
                            tabId: tab.id,
                            blockId: block.id,
                            itemIndex: item.originalIndex,
                            done: !item.done
                        )
                    }
                } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13.5))
                        .foregroundStyle(item.done ? Theme.Colors.green : Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            case .number:
                Text("\(displayIndex + 1).")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            case .bullet:
                Circle()
                    .fill(Theme.Colors.tertiaryText)
                    .frame(width: 4, height: 4)
                    .padding(.top, 5)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.done && style == .check ? Theme.Colors.textDim : Theme.Colors.text)
                    .strikethrough(item.done && style == .check, color: Theme.Colors.tertiaryText)
                if let note = item.note {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Timeline

    private func timeline(_ items: [TabBlockContent.TimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(i == 0 ? Theme.Colors.accent : Theme.Colors.tertiaryText.opacity(0.6))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        if i < items.count - 1 {
                            Rectangle()
                                .fill(Theme.Colors.border)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !items[i].date.isEmpty {
                                Text(items[i].date)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            Text(items[i].title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.Colors.text)
                        }
                        if let detail = items[i].detail {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, i < items.count - 1 ? 14 : 0)

                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Records embed

    @ViewBuilder
    private func recordsBlock(_ config: TabBlockContent.RecordsConfig) -> some View {
        // Resolve the target collection: the block's `collection` key, else
        // the tab's first. A stale key renders a fix-it card instead of
        // silently showing the wrong data.
        let resolved = config.collection.map { tab.collection(matching: $0) } ?? tab.sortedCollections.first
        if let collection = resolved {
            recordsBlockBody(config, collection: collection)
        } else {
            blockCard {
                Text(config.collection.map { "Records block: no collection '\($0)' on this tab — ask Otto to fix it." }
                     ?? "Records block: this tab has no collections yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private func recordsBlockBody(_ config: TabBlockContent.RecordsConfig, collection: TabCollection) -> some View {
        let all = appState.customRecords
            .filter { $0.tabId == tab.id && tab.collection(for: $0)?.id == collection.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        let shown = config.limit.map { Array(all.prefix($0)) } ?? all

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let title = config.title ?? block.title ?? (tab.collections.count > 1 ? collection.name : nil) {
                Text(title.uppercased())
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            if shown.isEmpty && config.view != .calendar {
                Text("No records yet — add rows here or ask Otto.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                switch config.view {
                case .list:
                    RecordListRows(tab: tab, collection: collection, records: shown, onOpen: onOpenRecord, onDelete: onDeleteRecord, horizontalPadding: 0)
                case .gallery:
                    RecordGalleryGrid(tab: tab, collection: collection, records: shown, onOpen: onOpenRecord, onDelete: onDeleteRecord)
                case .board:
                    RecordBoardView(
                        tab: tab,
                        collection: collection,
                        records: shown,
                        embedded: true,
                        onOpen: onOpenRecord,
                        onDelete: onDeleteRecord,
                        onAddToColumn: { preset in
                            var values: [UUID: CustomFieldValue] = [:]
                            if let option = preset.option {
                                values[preset.field.id] = .optionIds([option.id])
                            }
                            let record = CustomRecord(tabId: tab.id, collectionId: collection.id, values: values)
                            Task {
                                await appState.addCustomRecord(record)
                                onOpenRecord(record)
                            }
                        }
                    )
                case .calendar:
                    RecordCalendarView(
                        tab: tab,
                        collection: collection,
                        records: shown,
                        embedded: true,
                        dateFieldOverride: config.dateField,
                        onOpen: onOpenRecord,
                        onDelete: onDeleteRecord
                    )
                case .table, .dashboard:
                    RecordMiniTable(tab: tab, collection: collection, records: shown, onOpen: onOpenRecord, onDelete: onDeleteRecord)
                }

                if shown.count < all.count {
                    Text("Showing \(shown.count) of \(all.count) records")
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
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
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }
}

// MARK: - Mini table (records embed)

/// Read-only compact table for `records` blocks inside a dashboard — the
/// page scrolls vertically, the table only scrolls horizontally. Row click
/// opens the record editor.
struct RecordMiniTable: View {
    let tab: CustomTabDefinition
    let collection: TabCollection
    let records: [CustomRecord]
    let onOpen: (CustomRecord) -> Void
    let onDelete: (CustomRecord) -> Void

    @State private var hoveredRowId: UUID?

    private var fields: [CustomFieldDefinition] { collection.sortedFields }

    private var widths: [CGFloat] {
        fields.map { min($0.kind.defaultColumnWidth, 200) }
    }

    var body: some View {
        let widths = self.widths
        let total = widths.reduce(0, +)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                headerRow(widths)
                ForEach(records) { record in
                    row(record, widths: widths)
                }
            }
            .frame(width: total, alignment: .leading)
        }
    }

    private func headerRow(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(fields.indices, id: \.self) { i in
                Text(fields[i].name.uppercased())
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(width: widths[i], height: 26, alignment: .leading)
            }
        }
        .background(Theme.Colors.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    private func row(_ record: CustomRecord, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(fields.indices, id: \.self) { i in
                let field = fields[i]
                Group {
                    if let value = record.values[field.id] {
                        if case .optionIds = value {
                            CustomValueChip(field: field, value: value)
                        } else if case .bool = value {
                            CustomValueChip(field: field, value: value)
                        } else {
                            Text(value.displayString(for: field))
                                .font(.system(size: 12))
                                .foregroundStyle(i == 0 ? Theme.Colors.text : Theme.Colors.textDim)
                                .lineLimit(1)
                        }
                    } else {
                        Text("—")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
                    }
                }
                .padding(.horizontal, 7)
                .frame(width: widths[i], height: 30, alignment: .leading)
            }
        }
        .background(hoveredRowId == record.id ? Theme.Colors.hoverTint : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.borderSubtle).frame(height: 1)
        }
        .contentShape(Rectangle())
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
}
