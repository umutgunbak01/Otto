import SwiftUI

/// Create / edit a custom tab: name, sidebar icon, and its typed columns.
/// The first column doubles as the record's display title, and every column
/// becomes a parameter on the tab's generated `create_<slug>` / `update_<slug>`
/// agent tools.
struct CustomTabEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil when creating, non-nil when editing an existing tab.
    let existing: CustomTabDefinition?
    /// Called with the saved tab (create and edit). The sidebar uses it to
    /// select a freshly created tab.
    let onSave: ((CustomTabDefinition) -> Void)?

    @State private var name: String = ""
    @State private var icon: String = "tablecells"
    @State private var collections: [TabCollection] = []
    @State private var selectedCollectionId: UUID?
    @State private var layout: CustomTabLayout = .table
    @State private var editingField: FieldSheetTarget?
    @State private var showDeleteConfirm = false
    @State private var collectionPendingDelete: TabCollection?

    // The columns editor and pickers below all operate on the SELECTED
    // collection — these accessors keep their code reading flat.

    private var selectedIndex: Int? {
        if let id = selectedCollectionId, let i = collections.firstIndex(where: { $0.id == id }) { return i }
        return collections.isEmpty ? nil : 0
    }

    private var fields: [CustomFieldDefinition] {
        get { selectedIndex.map { collections[$0].fields } ?? [] }
        nonmutating set { if let i = selectedIndex { collections[i].fields = newValue } }
    }

    private var boardGroupFieldId: UUID? {
        get { selectedIndex.flatMap { collections[$0].boardGroupFieldId } }
        nonmutating set { if let i = selectedIndex { collections[i].boardGroupFieldId = newValue } }
    }

    private var dateFieldId: UUID? {
        get { selectedIndex.flatMap { collections[$0].dateFieldId } }
        nonmutating set { if let i = selectedIndex { collections[i].dateFieldId = newValue } }
    }

    /// Sheet target: edit one existing draft field, or add a new one.
    private struct FieldSheetTarget: Identifiable {
        let id = UUID()
        /// nil = new field.
        let field: CustomFieldDefinition?
    }

    private static let iconChoices: [String] = [
        "tablecells", "list.bullet", "book", "film", "music.note", "gamecontroller",
        "airplane", "cart", "creditcard", "gift", "heart", "star",
        "flag", "tag", "folder", "archivebox", "wrench.and.screwdriver", "paintpalette",
        "leaf", "pawprint", "car", "house", "graduationcap", "dumbbell",
        "fork.knife", "cup.and.saucer", "pills", "banknote", "chart.bar", "globe"
    ]

    init(existing: CustomTabDefinition? = nil, onSave: ((CustomTabDefinition) -> Void)? = nil) {
        self.existing = existing
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameField
                    iconPicker
                    layoutPicker
                    collectionsBar
                    fieldsEditor
                }
                .padding(16)
            }
            OttoDivider()
            footer
        }
        .frame(width: 460, height: 620)
        .background(Theme.Colors.bg2)
        .onAppear { hydrateFromExisting() }
        .sheet(item: $editingField) { target in
            CustomTabFieldEditorSheet(
                existing: target.field,
                // Kind changes would orphan stored values once the tab has
                // records — lock it when editing a field of a saved tab.
                lockKind: target.field != nil && existing != nil
            ) { saved in
                if let index = fields.firstIndex(where: { $0.id == saved.id }) {
                    fields[index] = saved
                } else {
                    fields.append(saved)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(existing?.name ?? "tab")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete tab and its records", role: .destructive) {
                if let existing = existing {
                    Task {
                        await appState.deleteCustomTab(existing)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every record in this tab will be removed. The agent's \(existing.map { "create_\($0.slug)" } ?? "")/update tools disappear with it.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(existing == nil ? "New tab" : "Edit tab")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.text)
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

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .hudLabel()
            TextField("e.g. Reading List", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(Theme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
            if let existing {
                Text("Agent tools: create_\(existing.slug) / update_\(existing.slug) (fixed at creation)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                let slug = CustomTabSlug.make(from: name, existing: appState.customTabs)
                Text("Agent tools will be: create_\(slug) / update_\(slug)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .hudLabel()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], spacing: 6) {
                ForEach(Self.iconChoices, id: \.self) { choice in
                    Button {
                        icon = choice
                    } label: {
                        Image(systemName: choice)
                            .font(.system(size: 13))
                            .frame(width: 34, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == choice ? Theme.Colors.selectTint : Theme.Colors.panel)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(icon == choice ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
                            )
                            .foregroundStyle(icon == choice ? Theme.Colors.accentText : Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Layout")
                .hudLabel()
            HStack(spacing: 6) {
                ForEach(CustomTabLayout.allCases, id: \.self) { choice in
                    Button {
                        layout = choice
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: choice.icon)
                                .font(.system(size: 13))
                            Text(choice.displayName)
                                .font(.system(size: 9.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(layout == choice ? Theme.Colors.selectTint : Theme.Colors.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(layout == choice ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
                        )
                        .foregroundStyle(layout == choice ? Theme.Colors.accentText : Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            if layout == .dashboard {
                Text("Dashboards are composed by Otto in chat — blocks like stats, charts, checklists, timelines, plus your records embedded.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            if layout == .board {
                boardGroupPicker
            }
            if layout == .calendar {
                dateFieldPicker
            }
        }
    }

    // MARK: Collections

    /// Chip per collection + add button; the columns editor below edits the
    /// selected one. Rename and delete live next to the selected chip.
    private var collectionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Collections")
                    .hudLabel()
                Text("separate record sets in one tab (e.g. Sessions + Meals)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            HStack(spacing: 6) {
                ForEach(collections) { collection in
                    let isSelected = selectedIndex.map { collections[$0].id == collection.id } ?? false
                    Button {
                        selectedCollectionId = collection.id
                    } label: {
                        Text(collection.name)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isSelected ? Theme.Colors.selectTint : Theme.Colors.panel))
                            .overlay(Capsule().strokeBorder(isSelected ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1))
                            .foregroundStyle(isSelected ? Theme.Colors.accentText : Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    addCollection()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Colors.textDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.Colors.panel))
                        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Add a collection")
                #endif
            }

            if let i = selectedIndex {
                HStack(spacing: 8) {
                    Text("Name")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textDim)
                    TextField("Collection name", text: Binding(
                        get: { collections[i].name },
                        set: { collections[i].name = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.border, lineWidth: 1))
                    .frame(maxWidth: 220)

                    if collections.count > 1 {
                        Button {
                            collectionPendingDelete = collections[i]
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .help("Delete this collection and its records")
                        #endif
                    }
                    Spacer()
                }
            }
        }
        .confirmationDialog(
            "Delete collection \"\(collectionPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { collectionPendingDelete != nil },
                set: { if !$0 { collectionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete collection and its records", role: .destructive) {
                if let target = collectionPendingDelete {
                    collections.removeAll { $0.id == target.id }
                    if selectedCollectionId == target.id { selectedCollectionId = collections.first?.id }
                }
                collectionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { collectionPendingDelete = nil }
        } message: {
            Text("Its records are removed when you save. Blocks referencing it show a fix-it note.")
        }
    }

    private func addCollection() {
        let name = "Collection \(collections.count + 1)"
        let collection = TabCollection(
            name: name,
            key: TabCollection.makeKey(from: name, existing: collections),
            fields: [CustomFieldDefinition(name: "Name", kind: .text)],
            sortIndex: (collections.map(\.sortIndex).max() ?? -1) + 1
        )
        collections.append(collection)
        selectedCollectionId = collection.id
    }

    @ViewBuilder
    private var dateFieldPicker: some View {
        let dateFields = fields.filter { $0.kind == .date }
        if dateFields.isEmpty {
            Text("Calendars place records by a date column — add one below.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.amber)
        } else {
            HStack(spacing: 6) {
                Text("Date column")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.textDim)
                Picker("", selection: Binding(
                    get: {
                        if let id = dateFieldId, dateFields.contains(where: { $0.id == id }) { return id }
                        return dateFields.first?.id ?? UUID()
                    },
                    set: { dateFieldId = $0 }
                )) {
                    ForEach(dateFields) { field in
                        Text(field.name).tag(field.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var boardGroupPicker: some View {
        let selectFields = fields.filter { $0.kind == .singleSelect }
        if selectFields.isEmpty {
            Text("Boards group by a single-select column — add one below (e.g. Status).")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.amber)
        } else {
            HStack(spacing: 6) {
                Text("Group by")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.textDim)
                Picker("", selection: Binding(
                    get: {
                        // Mirror CustomTabDefinition.boardGroupField's fallback.
                        if let id = boardGroupFieldId, selectFields.contains(where: { $0.id == id }) { return id }
                        return selectFields.first?.id ?? UUID()
                    },
                    set: { boardGroupFieldId = $0 }
                )) {
                    ForEach(selectFields) { field in
                        Text(field.name).tag(field.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var fieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Columns")
                .hudLabel()
            Text(layout == .dashboard
                 ? "Optional for dashboards — needed only if Otto keeps records here too."
                 : "The first column is the record's title.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: 4) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    HStack(spacing: 8) {
                        Image(systemName: field.kind.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .frame(width: 16)

                        Text(field.name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.text)

                        Text(field.kind.label)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        if field.kind.usesOptions && !field.options.isEmpty {
                            Text(field.options.map(\.label).joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            guard index > 0 else { return }
                            fields.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10))
                                .foregroundStyle(index > 0 ? Theme.Colors.textDim : Theme.Colors.tertiaryText.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)

                        Button {
                            guard index < fields.count - 1 else { return }
                            fields.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(index < fields.count - 1 ? Theme.Colors.textDim : Theme.Colors.tertiaryText.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .disabled(index == fields.count - 1)

                        Button {
                            editingField = FieldSheetTarget(field: field)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                        .buttonStyle(.plain)

                        Button {
                            fields.removeAll { $0.id == field.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
            }

            Button {
                editingField = FieldSheetTarget(field: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 12))
                    Text("Add column").font(.system(size: 12))
                }
                .foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var footer: some View {
        HStack {
            if existing != nil {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Delete tab")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.red)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("Cancel").font(.system(size: 12)).foregroundStyle(Theme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
            Button {
                save()
            } label: {
                Text(existing == nil ? "Create" : "Save")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!canSave)
        }
        .padding(12)
    }

    // MARK: Actions

    private func hydrateFromExisting() {
        if let existing = existing {
            name = existing.name
            icon = existing.icon
            collections = existing.sortedCollections
            selectedCollectionId = collections.first?.id
            layout = existing.layout
        } else {
            // Seed one collection with a title column so a new tab is one
            // click from usable.
            let seed = TabCollection(name: "Items", key: "items", fields: [CustomFieldDefinition(name: "Name", kind: .text)])
            collections = [seed]
            selectedCollectionId = seed.id
        }
    }

    /// Draft collections normalized for saving: display-order sort indexes
    /// re-stamped, stale board/date field pointers dropped, empty-name
    /// fallbacks applied, and NEW collections re-minted so their fixed key
    /// derives from the final name (not the "Collection 2" placeholder).
    private func normalizedCollections() -> [TabCollection] {
        let existingIds = Set(existing?.collections.map(\.id) ?? [])
        var out: [TabCollection] = []
        for (ci, var collection) in collections.enumerated() {
            collection.sortIndex = ci
            if collection.name.trimmingCharacters(in: .whitespaces).isEmpty {
                collection.name = "Items"
            }
            collection.fields = collection.sortedFields.enumerated().map { index, field in
                var f = field
                f.sortIndex = index
                return f
            }
            if !collection.fields.contains(where: { $0.id == collection.boardGroupFieldId && $0.kind == .singleSelect }) {
                collection.boardGroupFieldId = nil
            }
            if !collection.fields.contains(where: { $0.id == collection.dateFieldId && $0.kind == .date }) {
                collection.dateFieldId = nil
            }
            if !existingIds.contains(collection.id) {
                collection = TabCollection(
                    id: collection.id,
                    name: collection.name,
                    key: TabCollection.makeKey(from: collection.name, existing: out),
                    fields: collection.fields,
                    boardGroupFieldId: collection.boardGroupFieldId,
                    dateFieldId: collection.dateFieldId,
                    sortIndex: ci
                )
            }
            out.append(collection)
        }
        return out
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if layout == .dashboard { return true }
        return collections.contains { !$0.fields.isEmpty }
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let normalized = normalizedCollections()

        if var existing = existing {
            existing.name = trimmedName
            existing.icon = icon
            existing.collections = normalized
            existing.layout = layout
            Task {
                await appState.updateCustomTab(existing)
                onSave?(existing)
                dismiss()
            }
        } else {
            Task {
                let tab = await appState.addCustomTab(
                    name: trimmedName,
                    icon: icon,
                    collections: normalized,
                    layout: layout
                )
                onSave?(tab)
                dismiss()
            }
        }
    }
}

// MARK: - Field editor (nested sheet)

/// Name + type + options for one column. Mirrors `CustomFieldEditorSheet`
/// (the Connections version) but writes back through a closure instead of
/// AppState, so it can edit draft fields on an unsaved tab.
private struct CustomTabFieldEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existing: CustomFieldDefinition?
    let lockKind: Bool
    let onSave: (CustomFieldDefinition) -> Void

    @State private var name: String = ""
    @State private var kind: CustomFieldKind = .text
    @State private var options: [CustomFieldOption] = []
    @State private var newOptionLabel: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "New column" : "Edit column")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
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

            OttoDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .hudLabel()
                        TextField("e.g. Status", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(8)
                            .background(Theme.Colors.bgInput)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            )
                    }

                    kindPicker

                    if kind.usesOptions {
                        optionsEditor
                    }
                }
                .padding(16)
            }

            OttoDivider()

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.system(size: 12)).foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                Button {
                    save()
                } label: {
                    Text(existing == nil ? "Add" : "Save")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420, height: 520)
        .background(Theme.Colors.bg2)
        .onAppear {
            guard let existing = existing else { return }
            name = existing.name
            kind = existing.kind
            options = existing.options
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type")
                .hudLabel()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CustomFieldKind.allCases, id: \.self) { k in
                    Button {
                        guard !lockKind else { return }
                        kind = k
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: k.icon).font(.system(size: 11))
                            Text(k.label).font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(kind == k ? Theme.Colors.selectTint : Theme.Colors.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(kind == k ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
                        )
                        .foregroundStyle(kind == k ? Theme.Colors.accentText : Theme.Colors.textDim)
                        .opacity(lockKind && kind != k ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(lockKind)
                }
            }

            if lockKind {
                Text("Type can't be changed once the tab is saved. Delete and recreate the column to switch.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options")
                .hudLabel()

            VStack(spacing: 4) {
                ForEach($options) { $option in
                    HStack(spacing: 6) {
                        Menu {
                            Button("Default") { option.colorHex = nil }
                            ForEach(CustomFieldOptionPalette.hexes, id: \.self) { hex in
                                Button {
                                    option.colorHex = hex
                                } label: {
                                    Text("●  \(hex)")
                                }
                            }
                        } label: {
                            Circle()
                                .fill(Color.fromHex(option.colorHex) ?? Theme.Colors.accent)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Theme.Colors.border, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        #endif

                        TextField("Option label", text: $option.label)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))

                        Button {
                            options.removeAll { $0.id == option.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: 6) {
                TextField("Add option…", text: $newOptionLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { addOption() }
                Button { addOption() } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(newOptionLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(6)
            .background(Theme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
        }
    }

    private func addOption() {
        let trimmed = newOptionLabel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextColor = CustomFieldOptionPalette.hexes[options.count % CustomFieldOptionPalette.hexes.count]
        options.append(CustomFieldOption(label: trimmed, colorHex: nextColor))
        newOptionLabel = ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let cleanedOptions = options
            .map { CustomFieldOption(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespaces), colorHex: $0.colorHex) }
            .filter { !$0.label.isEmpty }

        let saved = CustomFieldDefinition(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            kind: kind,
            options: kind.usesOptions ? cleanedOptions : [],
            sortIndex: existing?.sortIndex ?? 0,
            createdAt: existing?.createdAt ?? Date()
        )
        onSave(saved)
        dismiss()
    }
}
