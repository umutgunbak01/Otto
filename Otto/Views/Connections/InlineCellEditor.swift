import SwiftUI

// MARK: - ConnectionCell — top-level dispatcher for a single (row, column)
//
// Renders a read-only display by default. When `isEditing` is true (the
// list view's `editingCell` matches this row+column), shows the per-kind
// editor. Commits write through to `appState`; the list view is responsible
// for clearing `editingCell` after the commit closure runs.

struct ConnectionCell: View {
    @Environment(AppState.self) private var appState
    let column: ConnectionColumn
    let connection: Connection
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void

    var body: some View {
        switch column {
        case .builtIn(let b): builtInCell(b)
        case .custom(let fieldId): customCell(fieldId)
        }
    }

    // MARK: Built-in cells

    @ViewBuilder
    private func builtInCell(_ b: BuiltInColumn) -> some View {
        switch b {
        case .headline:
            ShortTextCell(
                value: connection.headline,
                placeholder: "Title",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commit(\.headline, value: new) }
            )
        case .company:
            ShortTextCell(
                value: connection.company,
                placeholder: "Company",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commit(\.company, value: new) }
            )
        case .email:
            ShortTextCell(
                value: connection.email ?? "",
                placeholder: "Email",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commitOptional(\.email, value: new) }
            )
        case .phone:
            ShortTextCell(
                value: connection.phone ?? "",
                placeholder: "Phone",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commitOptional(\.phone, value: new) }
            )
        case .location:
            ShortTextCell(
                value: connection.location,
                placeholder: "Location",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commit(\.location, value: new) }
            )
        case .education:
            ShortTextCell(
                value: connection.education ?? "",
                placeholder: "Education",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in commitOptional(\.education, value: new) }
            )
        case .birthday:
            DateCell(
                value: connection.birthday,
                placeholder: "Birthday",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in
                    var updated = connection
                    updated.birthday = new
                    Task { await appState.updateConnection(updated) }
                    onEndEdit()
                }
            )
        case .connectionDate:
            DateCell(
                value: connection.connectionDate,
                placeholder: "Date",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onCommit: { new in
                    var updated = connection
                    updated.connectionDate = new
                    Task { await appState.updateConnection(updated) }
                    onEndEdit()
                }
            )
        case .lastContactedAt:
            LastContactDisplay(date: connection.lastContactedAt)
        case .closeness:
            ClosenessMenuCell(connection: connection)
        case .category:
            CategoryMenuCell(connection: connection)
        case .tags:
            TagsCell(
                connection: connection,
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onEndEdit: onEndEdit
            )
        case .notes:
            LongTextCell(
                value: connection.notes,
                placeholder: "Notes",
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onEndEdit: onEndEdit,
                onCommit: { new in commit(\.notes, value: new) }
            )
        }
    }

    // MARK: Custom cells

    @ViewBuilder
    private func customCell(_ fieldId: UUID) -> some View {
        if let def = appState.connectionCustomFields.first(where: { $0.id == fieldId }) {
            CustomFieldCell(
                definition: def,
                value: connection.customFields[fieldId],
                isEditing: isEditing,
                onBeginEdit: onBeginEdit,
                onEndEdit: onEndEdit,
                onCommit: { newValue in
                    Task { await appState.setCustomFieldValue(on: connection.id, fieldId: fieldId, value: newValue) }
                    // Commit always closes the popover/menu in the table; the
                    // detail view's wrapper drives its own state and ignores this.
                    onEndEdit()
                }
            )
        } else {
            // Definition vanished mid-render — show nothing rather than crash.
            EmptyView()
        }
    }

    // MARK: Mutation helpers

    private func commit(_ keyPath: WritableKeyPath<Connection, String>, value: String) {
        var updated = connection
        updated[keyPath: keyPath] = value
        Task { await appState.updateConnection(updated) }
        onEndEdit()
    }

    private func commitOptional(_ keyPath: WritableKeyPath<Connection, String?>, value: String) {
        var updated = connection
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        updated[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
        Task { await appState.updateConnection(updated) }
        onEndEdit()
    }
}

// MARK: - Short text cell (single line)

private struct ShortTextCell: View {
    let value: String
    let placeholder: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onAppear {
                        draft = value
                        focused = true
                    }
                    .onSubmit { onCommit(draft) }
                    .onChange(of: focused) { _, new in
                        if !new { onCommit(draft) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
                    )
            } else {
                CellDisplayText(
                    text: value,
                    placeholder: placeholder,
                    onTap: onBeginEdit
                )
            }
        }
    }
}

// MARK: - Long text cell (popover)

private struct LongTextCell: View {
    let value: String
    let placeholder: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void
    let onCommit: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        CellDisplayText(
            text: value.replacingOccurrences(of: "\n", with: " "),
            placeholder: placeholder,
            onTap: onBeginEdit
        )
        .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { onEndEdit() } })) {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .frame(width: 360, height: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.Colors.borderSubtle.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Button("Cancel") { onEndEdit() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Button("Save") {
                        onCommit(draft)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.accent)
                }
                .font(.system(size: 12))
            }
            .padding(12)
            .onAppear { draft = value }
        }
    }
}

// MARK: - Date cell (popover)

private struct DateCell: View {
    let value: Date?
    let placeholder: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (Date?) -> Void

    @State private var draft: Date = Date()

    var body: some View {
        CellDisplayText(
            text: value.map { ConnectionDateFormat.short($0) } ?? "",
            placeholder: placeholder,
            onTap: onBeginEdit
        )
        .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { onCommit(draft) } })) {
            VStack(spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 280)

                HStack {
                    Button("Clear") { onCommit(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                    Spacer()
                    Button("Done") { onCommit(draft) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
            }
            .padding(12)
            .onAppear { draft = value ?? Date() }
        }
    }
}

// MARK: - Cell display text (the read-only label)

struct CellDisplayText: View {
    let text: String
    let placeholder: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
                        .italic()
                } else {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Last contact (read-only)

private struct LastContactDisplay: View {
    let date: Date?

    var body: some View {
        HStack(spacing: 0) {
            if let date = date {
                Text(ConnectionDateFormat.relative(date))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .help(ConnectionDateFormat.short(date))
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

// MARK: - Closeness / Category menu cells (extend the pre-existing pattern)

private struct ClosenessMenuCell: View {
    @Environment(AppState.self) private var appState
    let connection: Connection

    var body: some View {
        Menu {
            ForEach(ConnectionCloseness.allCases, id: \.self) { tier in
                Button {
                    var updated = connection
                    updated.closeness = tier
                    Task { await appState.updateConnection(updated) }
                } label: {
                    HStack {
                        Image(systemName: tier.icon)
                        Text(tier.label)
                        if connection.closeness == tier { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connection.closeness.icon).font(.system(size: 11))
                Text(connection.closeness.label).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(connection.closeness == .unknown ? Theme.Colors.tertiaryText : connection.closeness.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(connection.closeness == .unknown ? Theme.Colors.hoverTint : connection.closeness.color.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

private struct CategoryMenuCell: View {
    @Environment(AppState.self) private var appState
    let connection: Connection

    var body: some View {
        Menu {
            ForEach(ConnectionCategory.allCases, id: \.self) { cat in
                Button {
                    var updated = connection
                    updated.category = cat
                    Task { await appState.updateConnection(updated) }
                } label: {
                    HStack {
                        Image(systemName: cat.icon)
                        Text(cat.label)
                        if connection.category == cat { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: connection.category.icon).font(.system(size: 11))
                Text(connection.category.label).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(connection.category == .unknown ? Theme.Colors.tertiaryText : connection.category.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(connection.category == .unknown ? Theme.Colors.hoverTint : connection.category.color.opacity(0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

// MARK: - Tags cell (popover with chip picker + add)

private struct TagsCell: View {
    @Environment(AppState.self) private var appState
    let connection: Connection
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void

    @State private var draft: [String] = []
    @State private var newTag: String = ""

    var body: some View {
        Button(action: onBeginEdit) {
            HStack(spacing: 4) {
                if connection.tags.isEmpty {
                    Text("Tags")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
                        .italic()
                } else {
                    ForEach(connection.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(ContentType.connection.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(ContentType.connection.color.opacity(0.12))
                            )
                            .lineLimit(1)
                    }
                    if connection.tags.count > 3 {
                        Text("+\(connection.tags.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { commit() } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.tertiaryText)

                FlowLayout(spacing: 4) {
                    ForEach(draft, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.system(size: 11))
                            Button {
                                draft.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(ContentType.connection.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ContentType.connection.color.opacity(0.12)))
                    }
                }

                HStack {
                    TextField("Add tag…", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { addTag() }
                    Button { addTag() } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(6)
                .background(Theme.Colors.borderSubtle.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 4))

                HStack {
                    Spacer()
                    Button("Done") { commit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(12)
            .frame(width: 280)
            .onAppear {
                draft = connection.tags
                newTag = ""
            }
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !draft.contains(trimmed) else { return }
        draft.append(trimmed)
        newTag = ""
    }

    private func commit() {
        var updated = connection
        updated.tags = draft
        Task { await appState.updateConnection(updated) }
        onEndEdit()
    }
}

// MARK: - Custom field cell

struct CustomFieldCell: View {
    let definition: CustomFieldDefinition
    let value: CustomFieldValue?
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onEndEdit: () -> Void
    let onCommit: (CustomFieldValue?) -> Void

    @State private var textDraft: String = ""
    @State private var numberDraft: String = ""
    @State private var dateDraft: Date = Date()
    @State private var optionsDraft: [UUID] = []
    @FocusState private var focused: Bool

    var body: some View {
        switch definition.kind {
        case .text, .url:
            shortTextEditor
        case .longText:
            longTextEditor
        case .number:
            numberEditor
        case .date:
            dateEditor
        case .checkbox:
            checkboxEditor
        case .singleSelect:
            singleSelectEditor
        case .multiSelect:
            multiSelectEditor
        }
    }

    // MARK: text / url

    private var shortTextEditor: some View {
        Group {
            if isEditing {
                TextField(definition.name, text: $textDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onAppear {
                        textDraft = currentString
                        focused = true
                    }
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, new in if !new { commitText() } }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Colors.accent.opacity(0.4), lineWidth: 1))
            } else {
                CellDisplayText(text: currentString, placeholder: definition.name, onTap: onBeginEdit)
            }
        }
    }

    private var longTextEditor: some View {
        CellDisplayText(text: currentString.replacingOccurrences(of: "\n", with: " "), placeholder: definition.name, onTap: onBeginEdit)
            .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { onEndEdit() } })) {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $textDraft)
                        .font(.system(size: 12))
                        .frame(width: 360, height: 180)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Theme.Colors.borderSubtle.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 8) {
                        Button("Cancel") { onEndEdit() }.buttonStyle(.plain).foregroundStyle(Theme.Colors.tertiaryText)
                        Button("Save") { commitText() }.buttonStyle(.plain).foregroundStyle(Theme.Colors.accent)
                    }
                    .font(.system(size: 12))
                }
                .padding(12)
                .onAppear { textDraft = currentString }
            }
    }

    private var currentString: String {
        switch value {
        case .text(let s), .url(let s): return s
        default: return ""
        }
    }

    private func commitText() {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCommit(nil)
        } else {
            onCommit(definition.kind == .url ? .url(trimmed) : .text(trimmed))
        }
    }

    // MARK: number

    private var numberEditor: some View {
        Group {
            if isEditing {
                TextField(definition.name, text: $numberDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onAppear {
                        if case .number(let n) = value {
                            numberDraft = String(n)
                        } else {
                            numberDraft = ""
                        }
                        focused = true
                    }
                    .onSubmit { commitNumber() }
                    .onChange(of: focused) { _, new in if !new { commitNumber() } }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Colors.accent.opacity(0.4), lineWidth: 1))
            } else {
                let display: String = {
                    if case .number(let n) = value {
                        return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
                    }
                    return ""
                }()
                CellDisplayText(text: display, placeholder: definition.name, onTap: onBeginEdit)
            }
        }
    }

    private func commitNumber() {
        let trimmed = numberDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { onCommit(nil); return }
        if let n = Double(trimmed) { onCommit(.number(n)) } else { onEndEdit() }
    }

    // MARK: date

    private var dateEditor: some View {
        let display: String = {
            if case .date(let d) = value { return ConnectionDateFormat.short(d) }
            return ""
        }()
        return CellDisplayText(text: display, placeholder: definition.name, onTap: onBeginEdit)
            .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { onCommit(.date(dateDraft)) } })) {
                VStack(spacing: 8) {
                    DatePicker("", selection: $dateDraft, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(width: 280)
                    HStack {
                        Button("Clear") { onCommit(nil) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Colors.priorityUrgent)
                        Spacer()
                        Button("Done") { onCommit(.date(dateDraft)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                }
                .padding(12)
                .onAppear {
                    if case .date(let d) = value { dateDraft = d } else { dateDraft = Date() }
                }
            }
    }

    // MARK: checkbox

    private var checkboxEditor: some View {
        let on: Bool = {
            if case .bool(let b) = value { return b }
            return false
        }()
        return Button {
            onCommit(.bool(!on))
        } label: {
            HStack {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: single-select

    private var singleSelectEditor: some View {
        let selectedId: UUID? = {
            if case .optionIds(let ids) = value { return ids.first }
            return nil
        }()
        let selectedOption = definition.options.first(where: { $0.id == selectedId })
        return Menu {
            Button {
                onCommit(nil)
            } label: {
                HStack { Text("None"); if selectedId == nil { Image(systemName: "checkmark") } }
            }
            Divider()
            ForEach(definition.options) { option in
                Button {
                    onCommit(.optionIds([option.id]))
                } label: {
                    HStack {
                        Text(option.label)
                        if selectedId == option.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let opt = selectedOption {
                    let chipColor = Color.fromHex(opt.colorHex) ?? Theme.Colors.accent
                    Text(opt.label)
                        .font(.system(size: 11))
                        .foregroundStyle(chipColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(chipColor.opacity(0.15)))
                        .lineLimit(1)
                } else {
                    Text(definition.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
                        .italic()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    // MARK: multi-select

    private var multiSelectEditor: some View {
        let selectedIds: Set<UUID> = {
            if case .optionIds(let ids) = value { return Set(ids) }
            return []
        }()
        return Button(action: onBeginEdit) {
            HStack(spacing: 4) {
                if selectedIds.isEmpty {
                    Text(definition.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
                        .italic()
                } else {
                    let selectedOptions = definition.options.filter { selectedIds.contains($0.id) }
                    ForEach(selectedOptions.prefix(3)) { opt in
                        let chipColor = Color.fromHex(opt.colorHex) ?? Theme.Colors.accent
                        Text(opt.label)
                            .font(.system(size: 10))
                            .foregroundStyle(chipColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(chipColor.opacity(0.15)))
                            .lineLimit(1)
                    }
                    if selectedOptions.count > 3 {
                        Text("+\(selectedOptions.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 { commitMulti() } })) {
            VStack(alignment: .leading, spacing: 6) {
                Text(definition.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.tertiaryText)
                ForEach(definition.options) { opt in
                    let isOn = optionsDraft.contains(opt.id)
                    Button {
                        if isOn {
                            optionsDraft.removeAll { $0 == opt.id }
                        } else {
                            optionsDraft.append(opt.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isOn ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                            let chipColor = Color.fromHex(opt.colorHex) ?? Theme.Colors.accent
                            Text(opt.label).foregroundStyle(chipColor)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Spacer()
                    Button("Done") { commitMulti() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(12)
            .frame(width: 240)
            .onAppear {
                if case .optionIds(let ids) = value { optionsDraft = ids } else { optionsDraft = [] }
            }
        }
    }

    private func commitMulti() {
        if optionsDraft.isEmpty { onCommit(nil) } else { onCommit(.optionIds(optionsDraft)) }
    }
}
