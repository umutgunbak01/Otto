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
    @State private var linkedNetworkIds: [UUID]
    @State private var openPerson: NetworkEntry?

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
        _linkedNetworkIds = State(initialValue: company?.linkedNetworkEntryIds ?? [])
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

                    FormField(label: "PEOPLE (NETWORK HUB)") {
                        CompanyPeopleLinker(
                            linkedIds: $linkedNetworkIds,
                            companyName: name,
                            companyLocation: location,
                            onOpenPerson: { openPerson = $0 }
                        )
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Theme.Colors.bg1)
        .sheet(item: $openPerson) { person in
            NetworkEntryEditor(
                entry: appState.networkEntries.first(where: { $0.id == person.id }) ?? person,
                onClose: { openPerson = nil }
            )
            .environment(appState)
            .frame(minWidth: 600, minHeight: 640)
        }
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
            updated.linkedNetworkEntryIds = linkedNetworkIds
            await appState.updateCompany(updated)
        } else {
            let new = Company(
                name: trimmedName,
                type: type,
                location: location.trimmingCharacters(in: .whitespaces),
                isCustomer: isCustomer,
                commitmentAmount: amount,
                website: cleanWebsite.isEmpty ? nil : cleanWebsite,
                notes: notes,
                linkedNetworkEntryIds: linkedNetworkIds
            )
            await appState.addCompany(new)
        }
        dismiss()
    }
}

// MARK: - People linker

/// Lists the Network Hub people linked to a company and lets you add/remove
/// links. With an empty search it suggests people whose company text matches
/// this company's name; typing searches the whole network.
private struct CompanyPeopleLinker: View {
    @Binding var linkedIds: [UUID]
    let companyName: String
    let companyLocation: String
    var onOpenPerson: (NetworkEntry) -> Void

    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var adding = false

    private var allEntries: [NetworkEntry] { appState.networkEntries }

    private var linked: [NetworkEntry] {
        linkedIds.compactMap { id in allEntries.first { $0.id == id } }
    }

    private var candidates: [NetworkEntry] {
        let linkedSet = Set(linkedIds)
        let pool = allEntries.filter { !linkedSet.contains($0.id) }
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let key = LocationNormalizer.fold(companyName)
            guard key.count >= 2 else { return [] }
            return Array(pool.filter {
                let c = LocationNormalizer.fold($0.company)
                return !c.isEmpty && (c.contains(key) || key.contains(c))
            }.prefix(8))
        }
        return Array(pool.filter { $0.searchableContent.localizedCaseInsensitiveContains(q) }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if linked.isEmpty {
                Text("No people linked yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(linked) { e in
                    linkedRow(e)
                        .background(Theme.Colors.bg2)
                        .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
                }
            }

            Button { withAnimation { adding.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: adding ? "chevron.down" : "plus.circle").font(.system(size: 11))
                    Text(adding ? "Done" : "Link people").font(.system(size: 12))
                }
                .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)

            if adding {
                FormText(text: $search, placeholder: "Search people, or type a new name to create…")
                let q = search.trimmingCharacters(in: .whitespaces)
                if q.isEmpty && candidates.isEmpty {
                    Text("Type a name to search your network — or to create a new person.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    if q.isEmpty && !candidates.isEmpty {
                        Text("SUGGESTED · \(companyName.uppercased())").hudLabel(tracking: Theme.Tracking.wide)
                    }
                    VStack(spacing: 0) {
                        if !q.isEmpty {
                            createRow(name: q)
                        }
                        ForEach(candidates) { e in
                            Button { linkedIds.append(e.id) } label: {
                                personRowContent(e, trailingIcon: "plus", trailingTint: Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.Colors.borderSubtle, lineWidth: 1))
                }
            }
        }
    }

    /// Inline "create a new Network Hub person and link them" row. Pre-fills the
    /// person's company + city from this company so they land on the map.
    private func createRow(name: String) -> some View {
        Button { createAndLink(name) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.Colors.green).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create “\(name)”")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.text).lineLimit(1)
                    Text("New Network Hub person · \(companyName.isEmpty ? "linked here" : companyName)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Theme.Colors.green.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createAndLink(_ name: String) {
        let entry = NetworkEntry(
            company: companyName.trimmingCharacters(in: .whitespaces),
            name: name,
            location: companyLocation.trimmingCharacters(in: .whitespaces)
        )
        Task { await appState.addNetworkEntry(entry) }
        linkedIds.append(entry.id)
        search = ""
    }

    /// Linked row: tapping the person opens their detail; the × unlinks.
    private func linkedRow(_ e: NetworkEntry) -> some View {
        HStack(spacing: 0) {
            Button { onOpenPerson(e) } label: {
                personRowContent(e, trailingIcon: nil, trailingTint: .clear)
            }
            .buttonStyle(.plain)
            .help("Open \(e.name)'s details")

            Button { linkedIds.removeAll { $0 == e.id } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unlink")
        }
    }

    private func personRowContent(_ e: NetworkEntry, trailingIcon: String?, trailingTint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.individualType.icon)
                .font(.system(size: 11)).foregroundStyle(e.type.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.text).lineLimit(1)
                if !e.displayInfo.isEmpty {
                    Text(e.displayInfo).font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.tertiaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.system(size: 12)).foregroundStyle(trailingTint)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
