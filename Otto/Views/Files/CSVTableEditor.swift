import SwiftUI

// MARK: - CSV document

/// Parse/serialize for the editable CSV table. Unlike the old preview parser,
/// this scans the whole text so quoted commas, escaped quotes ("") and quoted
/// newlines survive a load → edit → save round trip. Serialization normalizes
/// line endings to \n and quotes only fields that need it.
enum CSVDocument {

    static func parse(_ raw: String) -> (headers: [String], rows: [[String]]) {
        // Normalize line endings FIRST. In a Swift String, "\r\n" is a single
        // grapheme Character that matches neither "\r" nor "\n" in a switch —
        // scanning a CRLF file without this turns the whole file into one row.
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < end, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"" where field.isEmpty:
                    // RFC 4180: a field is quoted only if it *starts* with a
                    // quote. A stray quote mid-field stays literal instead of
                    // flipping the parser into quoted mode for the rest of
                    // the file.
                    inQuotes = true
                case "\"":
                    field.append(ch)
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        // A field opened a quote and never closed it: the scan swallowed the
        // rest of the file. Fall back to forgiving line-based parsing so a
        // malformed file degrades to one bad row instead of one giant row.
        if inQuotes {
            rows = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { parseLine(String($0)) }
        }

        return normalized(rows)
    }

    /// Old-style single-line parse used as the malformed-file fallback.
    private static func parseLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private static func normalized(_ parsed: [[String]]) -> (headers: [String], rows: [[String]]) {
        var rows = parsed
        // Drop blank lines (same behavior as the old preview).
        rows.removeAll { r in r.allSatisfy { $0.isEmpty } }
        guard !rows.isEmpty else { return ([], []) }

        // Normalize ragged rows so every row has the same column count.
        let columnCount = rows.map(\.count).max() ?? 0
        for idx in rows.indices where rows[idx].count < columnCount {
            rows[idx].append(contentsOf: Array(repeating: "", count: columnCount - rows[idx].count))
        }

        return (rows[0], Array(rows.dropFirst()))
    }

    static func serialize(headers: [String], rows: [[String]]) -> String {
        ([headers] + rows).map(line).joined(separator: "\n") + "\n"
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - Editable CSV table

/// Spreadsheet-style CSV view in the Network Hub table idiom: mono uppercase
/// headers, hairline grid, hover tint, click-to-edit cells that commit on
/// blur/return. The header stays pinned while rows scroll vertically; the
/// whole grid scrolls horizontally as one unit. Every mutation re-serializes
/// and hands the full text to `onSave` (nil → read-only display).
struct CSVTableEditor: View {
    let csvText: String
    var onSave: ((String) -> Void)?

    @State private var headers: [String]
    @State private var rows: [[String]]
    @State private var columnWidths: [CGFloat]
    @State private var editing: EditingCell?
    @State private var hoveredRow: Int?

    private var editable: Bool { onSave != nil }

    private struct EditingCell: Equatable {
        var row: Int   // -1 = header
        var col: Int
    }

    init(csvText: String, onSave: ((String) -> Void)? = nil) {
        self.csvText = csvText
        self.onSave = onSave
        let parsed = CSVDocument.parse(csvText)
        _headers = State(initialValue: parsed.headers)
        _rows = State(initialValue: parsed.rows)
        _columnWidths = State(initialValue: Self.fittedWidths(headers: parsed.headers, rows: parsed.rows))
    }

    // MARK: Column sizing

    private static let gutterWidth: CGFloat = 46
    private static let minColumn: CGFloat = 90
    private static let maxColumn: CGFloat = 340

    /// UI safety valve: a pathological file (thousands of columns) must not
    /// build thousands of cells per row. Data beyond the cap is preserved on
    /// save — just not shown.
    private static let maxDisplayColumns = 150

    private var displayColumns: Range<Int> {
        0..<min(headers.count, Self.maxDisplayColumns)
    }

    /// Fit each column to its header + a sample of its content, clamped so one
    /// long field can't blow the layout apart.
    private static func fittedWidths(headers: [String], rows: [[String]]) -> [CGFloat] {
        headers.indices.map { col in
            var longest = headers[col].count
            for row in rows.prefix(60) where col < row.count {
                longest = max(longest, min(row[col].count, 48))
            }
            return min(max(CGFloat(longest) * 7.2 + 22, minColumn), maxColumn)
        }
    }

    private var tableWidth: CGFloat {
        Self.gutterWidth + columnWidths.prefix(Self.maxDisplayColumns).reduce(0, +)
    }

    // MARK: Body

    var body: some View {
        if headers.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "tablecells")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Empty file")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        headerRow
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(rows.indices, id: \.self) { r in
                                    dataRow(r)
                                }
                            }
                        }
                    }
                    .frame(width: tableWidth, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                }

                OttoDivider()
                footer
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(Theme.Typography.label)
                .tracking(Theme.Tracking.xwide)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: Self.gutterWidth, height: TableMetrics.headerHeight)
                .cellTrailingDivider()

            ForEach(displayColumns, id: \.self) { c in
                headerCell(c)
            }
        }
        .background(Theme.Colors.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func headerCell(_ c: Int) -> some View {
        Group {
            if editable, editing == EditingCell(row: -1, col: c) {
                CSVCellField(
                    value: headers[c],
                    font: Theme.Typography.label,
                    onCommit: { newValue in
                        headers[c] = newValue
                        editing = nil
                        save()
                    },
                    onCancel: { editing = nil }
                )
            } else {
                Button {
                    if editable { editing = EditingCell(row: -1, col: c) }
                } label: {
                    Text(headers[c].isEmpty ? "—" : headers[c].uppercased())
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.xwide)
                        .foregroundStyle(headers[c].isEmpty ? Theme.Colors.tertiaryText.opacity(0.5) : Theme.Colors.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: columnWidths[c], height: TableMetrics.headerHeight)
        .cellTrailingDivider()
        .contextMenu {
            if editable {
                Button("Insert Column Before") { insertColumn(at: c) }
                Button("Insert Column After") { insertColumn(at: c + 1) }
                Divider()
                Button("Delete Column", role: .destructive) { deleteColumn(c) }
                    .disabled(headers.count <= 1)
            }
        }
    }

    // MARK: Rows

    private func dataRow(_ r: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(r + 1)")
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: Self.gutterWidth, height: TableMetrics.rowHeight)
                .cellTrailingDivider()

            ForEach(displayColumns, id: \.self) { c in
                dataCell(r, c)
            }
        }
        .background(rowBackground(r))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.borderSubtle).frame(height: 1)
        }
        .onHover { hovering in
            hoveredRow = hovering ? r : (hoveredRow == r ? nil : hoveredRow)
        }
        .contextMenu {
            if editable {
                Button("Insert Row Above") { insertRow(at: r) }
                Button("Insert Row Below") { insertRow(at: r + 1) }
                Divider()
                Button("Delete Row", role: .destructive) { deleteRow(r) }
            }
        }
    }

    private func rowBackground(_ r: Int) -> Color {
        if hoveredRow == r { return Theme.Colors.hoverTint }
        return r % 2 == 1 ? Theme.Colors.bg1.opacity(0.35) : Color.clear
    }

    @ViewBuilder
    private func dataCell(_ r: Int, _ c: Int) -> some View {
        Group {
            if editable, editing == EditingCell(row: r, col: c) {
                CSVCellField(
                    value: value(r, c),
                    font: .system(size: 12.5),
                    onCommit: { newValue in
                        setValue(newValue, r, c)
                        editing = nil
                        save()
                    },
                    onCancel: { editing = nil }
                )
            } else {
                Button {
                    if editable { editing = EditingCell(row: r, col: c) }
                } label: {
                    Text(value(r, c).isEmpty ? "—" : value(r, c))
                        .font(.system(size: 12.5))
                        .foregroundStyle(value(r, c).isEmpty ? Theme.Colors.tertiaryText.opacity(0.5) : Theme.Colors.text)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!editable)
            }
        }
        .frame(width: columnWidths[c], height: TableMetrics.rowHeight)
        .cellTrailingDivider()
    }

    private func value(_ r: Int, _ c: Int) -> String {
        guard r < rows.count, c < rows[r].count else { return "" }
        return rows[r][c]
    }

    private func setValue(_ v: String, _ r: Int, _ c: Int) {
        guard r < rows.count else { return }
        while rows[r].count <= c { rows[r].append("") }
        rows[r][c] = v
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Text(verbatim:) — interpolated Ints in a plain Text get
            // locale-formatted ("13.609"), which reads as a decimal here.
            Text(verbatim: "\(rows.count) row\(rows.count == 1 ? "" : "s") • \(headers.count) column\(headers.count == 1 ? "" : "s")")
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.tertiaryText)

            if headers.count > Self.maxDisplayColumns {
                Text(verbatim: "showing first \(Self.maxDisplayColumns) columns")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.amber)
            }

            if editable {
                Text("Click a cell to edit — changes save to the file")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.7))
            }

            Spacer()

            if editable {
                Button {
                    rows.append(Array(repeating: "", count: headers.count))
                    save()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Add Row")
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.bg1)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.bg1.opacity(0.6))
    }

    // MARK: Mutations

    private func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: headers.count), at: min(index, rows.count))
        save()
    }

    private func deleteRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
        editing = nil
        save()
    }

    private func insertColumn(at index: Int) {
        let at = min(index, headers.count)
        headers.insert("", at: at)
        columnWidths.insert(Self.minColumn, at: at)
        for r in rows.indices {
            rows[r].insert("", at: min(at, rows[r].count))
        }
        editing = EditingCell(row: -1, col: at)
        save()
    }

    private func deleteColumn(_ index: Int) {
        guard headers.count > 1, headers.indices.contains(index) else { return }
        headers.remove(at: index)
        columnWidths.remove(at: index)
        for r in rows.indices where rows[r].indices.contains(index) {
            rows[r].remove(at: index)
        }
        editing = nil
        save()
    }

    private func save() {
        onSave?(CSVDocument.serialize(headers: headers, rows: rows))
    }
}

// MARK: - Focused cell editor

/// The in-place TextField shown for the cell being edited. Commits on
/// return/blur, cancels on Escape (blur after cancel must not re-commit).
private struct CSVCellField: View {
    let value: String
    let font: Font
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.Colors.text)
            .focused($focused)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.bgInput)
            .onAppear {
                draft = value
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand {
                cancelled = true
                onCancel()
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        guard !cancelled else { return }
        cancelled = true  // guard against submit+blur double-fire
        if draft != value {
            onCommit(draft)
        } else {
            onCancel()
        }
    }
}
