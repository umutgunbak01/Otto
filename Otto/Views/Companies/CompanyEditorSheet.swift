import SwiftUI

/// Create or edit a Company. Pass `company` to edit; nil to create.
struct CompanyEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let company: Company?

    @State private var name: String
    @State private var type: CompanyType
    @State private var location: String
    @State private var isCustomer: Bool
    @State private var commitmentText: String
    @State private var website: String
    @State private var notes: String

    private var isEditing: Bool { company != nil }

    init(company: Company?) {
        self.company = company
        _name = State(initialValue: company?.name ?? "")
        _type = State(initialValue: company?.type ?? .unknown)
        _location = State(initialValue: company?.location ?? "")
        _isCustomer = State(initialValue: company?.isCustomer ?? false)
        _commitmentText = State(initialValue: MoneyField.string(from: company?.commitmentAmount))
        _website = State(initialValue: company?.website ?? "")
        _notes = State(initialValue: company?.notes ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    FormField(label: "NAME") {
                        FormText(text: $name, placeholder: "e.g. Acme AI")
                    }

                    FormField(label: "TYPE") {
                        Picker("", selection: $type) {
                            ForEach(CompanyType.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.Colors.cyan)
                    }

                    FormField(label: "CITY") {
                        FormText(text: $location, placeholder: "e.g. San Francisco")
                    }

                    Toggle(isOn: $isCustomer) {
                        Text("Customer")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.Colors.green)

                    FormField(label: isCustomer ? "COMMITMENT ($)" : "POTENTIAL ($)") {
                        FormText(text: $commitmentText, placeholder: "e.g. 50000")
                    }

                    FormField(label: "WEBSITE (optional)") {
                        FormText(text: $website, placeholder: "acme.ai")
                    }

                    FormField(label: "NOTES") {
                        FormTextEditor(text: $notes, placeholder: "Context, deal status, who to talk to…")
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Theme.Colors.bg1)
    }

    private var header: some View {
        HStack {
            Text(isEditing ? "EDIT COMPANY" : "NEW COMPANY")
                .hudLabel(tracking: Theme.Tracking.xxwide, color: Theme.Colors.cyan)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("DELETE", role: .destructive) {
                    if let company { Task { await appState.deleteCompany(company); dismiss() } }
                }
                .buttonStyle(GhostButtonStyle())
                .foregroundStyle(Theme.Colors.red)
            }
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Button(isEditing ? "SAVE" : "CREATE") { Task { await save() } }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
        }
        .padding(Theme.Spacing.lg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let amount = MoneyField.amount(from: commitmentText)
        let cleanWebsite = website.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = company {
            var updated = existing
            updated.name = trimmedName
            updated.type = type
            updated.location = location.trimmingCharacters(in: .whitespaces)
            updated.isCustomer = isCustomer
            updated.commitmentAmount = amount
            updated.website = cleanWebsite.isEmpty ? nil : cleanWebsite
            updated.notes = notes
            await appState.updateCompany(updated)
        } else {
            let new = Company(
                name: trimmedName,
                type: type,
                location: location.trimmingCharacters(in: .whitespaces),
                isCustomer: isCustomer,
                commitmentAmount: amount,
                website: cleanWebsite.isEmpty ? nil : cleanWebsite,
                notes: notes
            )
            await appState.addCompany(new)
        }
        dismiss()
    }
}
