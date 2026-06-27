import SwiftUI

/// Reusable spreadsheet-style cells whose values commit inline (on blur / pick /
/// toggle) without opening a detail sheet. Modeled on the Network Hub table's
/// `NHEditableCell`/`NHEnumCell`, generalized so every entity table can share them.

enum TableMetrics {
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 28
}

extension View {
    /// Thin vertical rule on a cell's trailing edge (keeps columns aligned).
    func cellTrailingDivider() -> some View {
        overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Colors.border.opacity(0.4)).frame(width: 1)
        }
    }
}

// MARK: - Header

struct TableHeaderCell: View {
    let title: String
    let width: CGFloat
    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 7)
            .frame(width: width, height: TableMetrics.headerHeight, alignment: .leading)
            .cellTrailingDivider()
    }
}

// MARK: - Open / expand button

struct OpenRowCell: View {
    let width: CGFloat
    var tint: Color = Theme.Colors.tertiaryText
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: width, height: TableMetrics.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open full editor")
        .cellTrailingDivider()
    }
}

// MARK: - Editable text cell

struct InlineTextCell: View {
    let text: String
    let width: CGFloat
    var placeholder: String = "—"
    var bold: Bool = false
    var tint: Color = Theme.Colors.text
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: bold ? .medium : .regular))
            .foregroundStyle(tint)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, nv in if !focused { draft = nv } }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != text { onCommit(draft) }
            }
            .onSubmit { if draft != text { onCommit(draft) } }
            .padding(.horizontal, 7)
            .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
            .background(focused ? Theme.Colors.selectTint : Color.clear)
            .cellTrailingDivider()
    }
}

// MARK: - Inline enum dropdown cell

struct InlineEnumCell<T: Hashable>: View {
    let width: CGFloat
    let value: T
    let options: [T]
    let title: (T) -> String
    let icon: (T) -> String
    let color: (T) -> Color
    let onPick: (T) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { onPick(o) } label: {
                    HStack {
                        Image(systemName: icon(o))
                        Text(title(o))
                        if o == value { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(value)).font(.system(size: 10))
                Text(title(value)).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 2)
            }
            .foregroundStyle(color(value))
            .padding(.horizontal, 7)
            .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .cellTrailingDivider()
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

// MARK: - Toggle cell (e.g. is-customer)

struct InlineToggleCell: View {
    let isOn: Bool
    let width: CGFloat
    var onText: String = "Yes"
    let onToggle: (Bool) -> Void
    var body: some View {
        Button { onToggle(!isOn) } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                Text(isOn ? onText : "—").font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? Theme.Colors.green : Theme.Colors.tertiaryText)
            .padding(.horizontal, 7)
            .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .cellTrailingDivider()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Money cell ($ amount; formatted when blurred, raw while editing)

struct InlineMoneyCell: View {
    let amount: Double?
    let width: CGFloat
    var tint: Color = Theme.Colors.green
    let onCommit: (Double?) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var display: String {
        guard let a = amount, a > 0 else { return "" }
        return Company.formatMoney(a)
    }

    var body: some View {
        TextField("$", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .focused($focused)
            .onAppear { draft = display }
            .onChange(of: amount) { _, _ in if !focused { draft = display } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    draft = MoneyField.string(from: amount)   // raw while editing
                } else {
                    let parsed = MoneyField.amount(from: draft)
                    if parsed != amount { onCommit(parsed) }
                    draft = display                           // formatted when blurred
                }
            }
            .onSubmit {
                let parsed = MoneyField.amount(from: draft)
                if parsed != amount { onCommit(parsed) }
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
            .background(focused ? Theme.Colors.selectTint : Color.clear)
            .cellTrailingDivider()
    }
}

// MARK: - Optional date cell

struct InlineDateCell: View {
    let date: Date?
    let width: CGFloat
    let onCommit: (Date?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { onCommit($0) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .font(.system(size: 11))
                Button { onCommit(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            } else {
                Button { onCommit(Date()) } label: {
                    Text("Set date").font(.system(size: 11)).foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
        .cellTrailingDivider()
    }
}

// MARK: - Read-only badge cell (used in the "All" overview tab)

struct InlineBadgeCell: View {
    let icon: String
    let text: String
    let color: Color
    let width: CGFloat
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(width: width, height: TableMetrics.rowHeight, alignment: .leading)
        .cellTrailingDivider()
    }
}

// MARK: - Shared toolbar pieces

struct TableSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.tertiaryText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.Colors.hoverTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .frame(maxWidth: 300)
    }
}

struct TableFilterChip: View {
    let icon: String
    let text: String
    let isActive: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Theme.Colors.accent.opacity(0.1) : Theme.Colors.borderSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
