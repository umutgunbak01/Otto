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
    @State private var fields: [CustomFieldDefinition] = []
    @State private var editingField: FieldSheetTarget?
    @State private var showDeleteConfirm = false

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

    private var fieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Columns")
                .hudLabel()
            Text("The first column is the record's title.")
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
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || fields.isEmpty)
        }
        .padding(12)
    }

    // MARK: Actions

    private func hydrateFromExisting() {
        if let existing = existing {
            name = existing.name
            icon = existing.icon
            fields = existing.sortedFields
        } else {
            // Seed a sensible title column so a new tab is one click from usable.
            fields = [CustomFieldDefinition(name: "Name", kind: .text)]
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !fields.isEmpty else { return }
        // Re-stamp sortIndex from display order.
        let ordered = fields.enumerated().map { index, field -> CustomFieldDefinition in
            var f = field
            f.sortIndex = index
            return f
        }

        if var existing = existing {
            existing.name = trimmedName
            existing.icon = icon
            existing.fields = ordered
            Task {
                await appState.updateCustomTab(existing)
                onSave?(existing)
                dismiss()
            }
        } else {
            Task {
                let tab = await appState.addCustomTab(name: trimmedName, icon: icon, fields: ordered)
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
