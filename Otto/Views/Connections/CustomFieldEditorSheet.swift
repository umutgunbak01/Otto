import SwiftUI

/// Create / edit a `CustomFieldDefinition`. Reused for both "+ New custom
/// field" and "Edit options" flows from the Columns menu.
struct CustomFieldEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil when creating, non-nil when editing an existing definition.
    let existing: CustomFieldDefinition?

    @State private var name: String = ""
    @State private var kind: CustomFieldKind = .text
    @State private var options: [CustomFieldOption] = []
    @State private var newOptionLabel: String = ""
    @State private var showDeleteConfirm: Bool = false

    init(existing: CustomFieldDefinition? = nil) {
        self.existing = existing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameField
                    kindPicker
                    if kind.usesOptions {
                        optionsEditor
                    }
                }
                .padding(16)
            }
            OttoDivider()
            footer
        }
        .frame(width: 420, height: 560)
        .onAppear { hydrateFromExisting() }
        .confirmationDialog(
            "Delete \(existing?.name ?? "field")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete field", role: .destructive) {
                if let existing = existing {
                    Task {
                        await appState.deleteCustomField(id: existing.id)
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Values on every connection will be removed. This can't be undone.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text(existing == nil ? "New custom field" : "Edit custom field")
                .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
            TextField("e.g. Lead status", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(Theme.Colors.borderSubtle.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            // Disable kind change when editing — switching the type of an
            // existing field would orphan every value already stored.
            let isLocked = existing != nil

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CustomFieldKind.allCases, id: \.self) { k in
                    Button {
                        guard !isLocked else { return }
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
                                .fill(kind == k ? Theme.Colors.accent.opacity(0.18) : Theme.Colors.borderSubtle.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(kind == k ? Theme.Colors.accent : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(kind == k ? Theme.Colors.accent : Theme.Colors.text)
                        .opacity(isLocked && kind != k ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                }
            }

            if isLocked {
                Text("Type can't be changed after creation. Delete and recreate to switch.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: 4) {
                ForEach($options) { $option in
                    HStack(spacing: 6) {
                        // Color swatch picker
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
                    .background(Theme.Colors.borderSubtle.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
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
            .background(Theme.Colors.borderSubtle.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var footer: some View {
        HStack {
            if existing != nil {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Delete")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.priorityUrgent)
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.accent))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    // MARK: Actions

    private func hydrateFromExisting() {
        guard let existing = existing else { return }
        name = existing.name
        kind = existing.kind
        options = existing.options
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

        if var existing = existing {
            existing.name = trimmedName
            existing.options = kind.usesOptions ? cleanedOptions : []
            Task {
                await appState.updateCustomField(existing)
                dismiss()
            }
        } else {
            Task {
                await appState.addCustomField(name: trimmedName, kind: kind, options: cleanedOptions)
                dismiss()
            }
        }
    }
}
