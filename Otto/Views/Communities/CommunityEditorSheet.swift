import SwiftUI

/// Create or edit a Community. Pass `community` to edit; nil to create.
struct CommunityEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let community: Community?

    @State private var name: String
    @State private var type: CommunityType
    @State private var location: String
    @State private var builderSupportPerk: Bool
    @State private var url: String
    @State private var notes: String

    private var isEditing: Bool { community != nil }

    init(community: Community?) {
        self.community = community
        _name = State(initialValue: community?.name ?? "")
        _type = State(initialValue: community?.type ?? .community)
        _location = State(initialValue: community?.location ?? "")
        _builderSupportPerk = State(initialValue: community?.builderSupportPerk ?? false)
        _url = State(initialValue: community?.url ?? "")
        _notes = State(initialValue: community?.notes ?? "")
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    FormField(label: "NAME") { FormText(text: $name, placeholder: "e.g. AI Weekend") }
                    FormField(label: "TYPE") {
                        Picker("", selection: $type) {
                            ForEach(CommunityType.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu).tint(Theme.Colors.cyan)
                    }
                    FormField(label: "CITY") { FormText(text: $location, placeholder: "e.g. İstanbul") }
                    Toggle(isOn: $builderSupportPerk) {
                        Text("Offers a builder-support perk").font(Theme.Typography.body).foregroundStyle(Theme.Colors.text)
                    }
                    .toggleStyle(.switch).tint(Theme.Colors.amber)
                    FormField(label: "URL (optional)") { FormText(text: $url, placeholder: "community.com") }
                    FormField(label: "NOTES") { FormTextEditor(text: $notes, placeholder: "What is it, who runs it, how to engage…") }
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 540)
        .background(Theme.Colors.bg1)
    }

    private var header: some View {
        HStack {
            Text(isEditing ? "EDIT COMMUNITY" : "NEW COMMUNITY")
                .hudLabel(tracking: Theme.Tracking.xxwide)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Theme.Colors.textDim) }
                .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("DELETE", role: .destructive) {
                    if let community { Task { await appState.deleteCommunity(community); dismiss() } }
                }
                .buttonStyle(GhostButtonStyle()).foregroundStyle(Theme.Colors.red)
            }
            Spacer()
            Button("CANCEL") { dismiss() }.buttonStyle(GhostButtonStyle())
            Button(isEditing ? "SAVE" : "CREATE") { Task { await save() } }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave).opacity(canSave ? 1 : 0.5)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = community {
            var updated = existing
            updated.name = trimmedName
            updated.type = type
            updated.location = location.trimmingCharacters(in: .whitespaces)
            updated.builderSupportPerk = builderSupportPerk
            updated.url = cleanURL.isEmpty ? nil : cleanURL
            updated.notes = notes
            await appState.updateCommunity(updated)
        } else {
            let new = Community(
                name: trimmedName, type: type,
                location: location.trimmingCharacters(in: .whitespaces),
                builderSupportPerk: builderSupportPerk,
                url: cleanURL.isEmpty ? nil : cleanURL, notes: notes
            )
            await appState.addCommunity(new)
        }
        dismiss()
    }
}
