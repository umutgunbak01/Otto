import SwiftUI

// MARK: - Column widths (shared by header + rows so they stay aligned)

private enum NHCol {
    static let open: CGFloat = 32
    static let name: CGFloat = 180
    static let type: CGFloat = 125
    static let role: CGFloat = 120
    static let company: CGFloat = 150
    static let title: CGFloat = 165
    static let industry: CGFloat = 120
    static let location: CGFloat = 155
    static let email: CGFloat = 200
    static let closeness: CGFloat = 155
    static var total: CGFloat {
        open + name + type + role + company + title + industry + location + email + closeness
    }
}

/// Strategic Network Hub — a spreadsheet-style table whose cells are editable
/// inline (like Google Sheets); the row's expand button opens the full detail
/// sheet with the structured LinkedIn profile.
struct NetworkHubListView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .closeness
    @State private var filterType: NetworkType? = nil
    @State private var filterIndividualType: IndividualType? = nil
    @State private var filterCloseness: NetworkCloseness? = nil
    @State private var showFollowUpsOnly: Bool = false
    @State private var editingEntryId: UUID?
    @State private var isCreatingNew: Bool = false

    enum SortOption: String, CaseIterable {
        case closeness = "Closeness"
        case alphabetical = "A-Z"
        case company = "Company"
        case type = "Type"
    }

    private var filtered: [NetworkEntry] {
        var result = appState.networkEntries
        if !searchText.isEmpty {
            result = result.filter { $0.searchableContent.localizedCaseInsensitiveContains(searchText) }
        }
        if let type = filterType { result = result.filter { $0.type == type } }
        if let it = filterIndividualType { result = result.filter { $0.individualType == it } }
        if let c = filterCloseness { result = result.filter { $0.closeness == c } }

        if showFollowUpsOnly {
            // The follow-up queue: due people only, most overdue first.
            return result
                .compactMap { entry in entry.followUpOverdueDays().map { (entry, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }

        switch sortOption {
        case .alphabetical:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .company:
            result.sort {
                if $0.company.isEmpty != $1.company.isEmpty { return !$0.company.isEmpty }
                if $0.company.lowercased() == $1.company.lowercased() {
                    return $0.name.lowercased() < $1.name.lowercased()
                }
                return $0.company.lowercased() < $1.company.lowercased()
            }
        case .closeness:
            result.sort {
                if $0.closeness.rank == $1.closeness.rank {
                    return $0.name.lowercased() < $1.name.lowercased()
                }
                return $0.closeness.rank > $1.closeness.rank
            }
        case .type:
            result.sort {
                if $0.type.label == $1.type.label {
                    return $0.name.lowercased() < $1.name.lowercased()
                }
                return $0.type.label < $1.type.label
            }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            if appState.networkEntries.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                table
            }
        }
        .sheet(item: editorBinding) { item in
            NetworkEntryEditor(
                entry: appState.networkEntries.first(where: { $0.id == item.id }),
                onClose: { editingEntryId = nil; isCreatingNew = false }
            )
            .environment(appState)
        }
        .onChange(of: appState.locateItemId) { _, target in openLocatedEntry(target) }
        .onAppear { openLocatedEntry(appState.locateItemId) }
    }

    /// `appState.locate(type: .networkHub, id:)` handler — opens the person's
    /// editor sheet, mirroring the other list views' locate contract.
    private func openLocatedEntry(_ target: UUID?) {
        guard let target, appState.networkEntries.contains(where: { $0.id == target }) else { return }
        editingEntryId = target
        appState.locateItemId = nil
    }

    private var dueFollowUpCount: Int {
        appState.networkEntries.reduce(0) { $0 + ($1.followUpOverdueDays() != nil ? 1 : 0) }
    }

    // MARK: - Table

    private var table: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(spacing: 0) {
                tableHeader
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        NetworkTableRow(entry: entry, onOpen: { editingEntryId = entry.id })
                            .environment(appState)
                    }
                }
            }
            .frame(width: NHCol.total, alignment: .leading)
        }
        // Inset "sheet" container (mockup .sheetwrap): faint wash, rounded
        // hairline frame, floated off the pane edges.
        .background(Color.white.opacity(0.008))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            headerCell("", NHCol.open)
            headerCell("NAME", NHCol.name)
            headerCell("TYPE", NHCol.type)
            headerCell("ROLE", NHCol.role)
            headerCell("COMPANY", NHCol.company)
            headerCell("TITLE", NHCol.title)
            headerCell("INDUSTRY", NHCol.industry)
            headerCell("LOCATION", NHCol.location)
            headerCell("EMAIL", NHCol.email)
            headerCell("CLOSENESS", NHCol.closeness)
        }
        .background(Theme.Colors.bgRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    private func headerCell(_ t: String, _ w: CGFloat) -> some View {
        Text(t)
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 7)
            .frame(width: w, height: 28, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.Colors.border).frame(width: 1)
            }
    }

    // MARK: - Toolbar

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Title row (mockup .viewbar): serif display title + mono count chip.
            HStack(alignment: .center, spacing: 10) {
                Text("Network hub")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountChip(text: "\(filtered.count) curated")

                Spacer(minLength: 8)
            }

            // Controls row: bordered menu buttons + mini search + primary CTA.
            HStack(spacing: Theme.Spacing.sm) {
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button { sortOption = option } label: {
                            HStack { Text(option.rawValue); if sortOption == option { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: "Sort: \(sortOption.rawValue)", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                Menu {
                    Button { filterType = nil } label: {
                        HStack { Text("All Types"); if filterType == nil { Image(systemName: "checkmark") } }
                    }
                    Divider()
                    ForEach(NetworkType.allCases, id: \.self) { t in
                        Button { filterType = t } label: {
                            HStack { Image(systemName: t.icon); Text(t.label); if filterType == t { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: filterType?.label ?? "Type", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                Menu {
                    Button { filterIndividualType = nil } label: {
                        HStack { Text("All Roles"); if filterIndividualType == nil { Image(systemName: "checkmark") } }
                    }
                    Divider()
                    ForEach(IndividualType.allCases, id: \.self) { it in
                        Button { filterIndividualType = it } label: {
                            HStack { Image(systemName: it.icon); Text(it.label); if filterIndividualType == it { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: filterIndividualType?.label ?? "Role", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                Menu {
                    Button { filterCloseness = nil } label: {
                        HStack { Text("All"); if filterCloseness == nil { Image(systemName: "checkmark") } }
                    }
                    Divider()
                    ForEach(NetworkCloseness.allCases, id: \.self) { c in
                        Button { filterCloseness = c } label: {
                            HStack { Image(systemName: c.icon); Text(c.label); if filterCloseness == c { Image(systemName: "checkmark") } }
                        }
                    }
                } label: {
                    OttoBarButtonLabel(label: filterCloseness?.label ?? "Closeness", showsCaret: true)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                #endif

                // Keep-in-touch queue toggle (active-state pill; the shared
                // bar-button primitive has no selected look).
                Button {
                    showFollowUpsOnly.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.wave")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(showFollowUpsOnly ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                        Text(dueFollowUpCount > 0 ? "Follow-ups · \(dueFollowUpCount)" : "Follow-ups")
                            .font(.system(size: 11.5))
                            .foregroundStyle(showFollowUpsOnly ? Theme.Colors.accentText : Theme.Colors.textDim)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(showFollowUpsOnly ? Theme.Colors.selectTint : Theme.Colors.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(showFollowUpsOnly ? Color.clear : Theme.Colors.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                OttoSearchMini(placeholder: "Search name, company, title…", text: $searchText, width: 230)

                OttoNewButton(label: "Add") {
                    isCreatingNew = true
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: ContentType.networkHub.iconName)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No network entries").font(Theme.Typography.body).foregroundStyle(Theme.Colors.tertiaryText)
            Button { isCreatingNew = true } label: {
                Text("Add the first one").font(Theme.Typography.body).foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No results").font(Theme.Typography.body).foregroundStyle(Theme.Colors.tertiaryText)
            Button {
                searchText = ""; filterType = nil; filterIndividualType = nil; filterCloseness = nil
            } label: {
                Text("Clear filters").font(Theme.Typography.body).foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor sheet binding

    private struct EditorItem: Identifiable { let id: UUID }

    private var editorBinding: Binding<EditorItem?> {
        Binding(
            get: {
                if isCreatingNew { return EditorItem(id: NetworkEntryEditor.newSentinel) }
                if let id = editingEntryId,
                   appState.networkEntries.contains(where: { $0.id == id }) {
                    return EditorItem(id: id)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil { editingEntryId = nil; isCreatingNew = false }
            }
        )
    }
}

// MARK: - Table row (inline-editable cells)

private struct NetworkTableRow: View {
    let entry: NetworkEntry
    let onOpen: () -> Void

    @Environment(AppState.self) private var appState
    @State private var hover = false

    private func commit(_ mutate: (inout NetworkEntry) -> Void) {
        var u = entry
        mutate(&u)
        Task { await appState.updateNetworkEntry(u) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.profile != nil ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                    .frame(width: NHCol.open, height: 34)
            }
            .buttonStyle(.plain)
            .help(entry.profile != nil ? "Open details (LinkedIn profile attached)" : "Open details")
            .overlay(alignment: .trailing) { gridLine }

            NHEditableCell(text: entry.name, width: NHCol.name, placeholder: "Name", bold: true, avatarName: entry.name) { v in commit { $0.name = v } }
            NHEnumCell(width: NHCol.type, value: entry.type, options: NetworkType.allCases,
                       title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit { $0.type = v } }
            NHEnumCell(width: NHCol.role, value: entry.individualType, options: IndividualType.allCases,
                       title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit { $0.individualType = v } }
            NHEditableCell(text: entry.company, width: NHCol.company) { v in commit { $0.company = v } }
            NHEditableCell(text: entry.title, width: NHCol.title) { v in commit { $0.title = v } }
            NHEditableCell(text: entry.industry, width: NHCol.industry) { v in commit { $0.industry = v } }
            NHEditableCell(text: entry.location, width: NHCol.location) { v in commit { $0.location = v } }
            NHEditableCell(text: entry.email, width: NHCol.email) { v in commit { $0.email = v } }
            NHEnumCell(width: NHCol.closeness, value: entry.closeness, options: NetworkCloseness.allCases,
                       title: { $0.label }, icon: { $0.icon },
                       color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit { $0.closeness = v } }
        }
        .frame(height: 34)
        .background(hover ? Color.white.opacity(0.018) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.038)).frame(height: 1)
        }
        .onHover { hover = $0 }
    }

    private var gridLine: some View {
        Rectangle().fill(Theme.Colors.border).frame(width: 1)
    }
}

// MARK: - Editable text cell

private struct NHEditableCell: View {
    let text: String
    let width: CGFloat
    var placeholder: String = "—"
    var bold: Bool = false
    /// When set, a gradient initials avatar leads the field (NAME cell only).
    var avatarName: String? = nil
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let avatarName {
                OttoAvatar(name: avatarName, size: 24)
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: bold ? .medium : .regular))
                .foregroundStyle(bold ? Theme.Colors.text : Theme.Colors.textDim)
                .focused($focused)
                .onAppear { draft = text }
                .onChange(of: text) { _, nv in if !focused { draft = nv } }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, draft != text { onCommit(draft) }
                }
                .onSubmit { if draft != text { onCommit(draft) } }
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: 34, alignment: .leading)
        .background(focused ? Theme.Colors.selectTint : Color.clear)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Colors.border).frame(width: 1)
        }
    }
}

// MARK: - Inline enum dropdown cell

private struct NHEnumCell<T: Hashable>: View {
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
            HStack(spacing: 5) {
                Text(title(value))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(color(value))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color(value).opacity(0.10))
                    )
                Text("▾")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: 34, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.Colors.border).frame(width: 1)
            }
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

// MARK: - Editor sheet

struct NetworkEntryEditor: View {
    static let newSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let entry: NetworkEntry?
    let onClose: () -> Void

    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var type: NetworkType = .startup
    @State private var company: String = ""
    @State private var industry: String = ""
    @State private var individualType: IndividualType = .founder
    @State private var title: String = ""
    @State private var location: String = ""
    @State private var email: String = ""
    @State private var linkedin: String = ""
    @State private var closeness: NetworkCloseness = .lightConnection
    @State private var notes: String = ""
    @State private var followUpCadence: FollowUpCadence? = nil
    @State private var didLoad = false
    /// Merged interaction history for the timeline + dossier context,
    /// computed once per sheet open (a full index build is ~tens of ms).
    @State private var touchpoints: [Touchpoint] = []

    private var dossier: PersonDossierService { .shared }

    private var isEditing: Bool { entry != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit entry" : "New entry")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.Colors.bg1)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name") { TextField("Full name", text: $name).textFieldStyle(.plain) }

                    HStack(spacing: 14) {
                        picker("Type", selection: $type, options: NetworkType.allCases) { $0.label }
                        picker("Role", selection: $individualType, options: IndividualType.allCases) { $0.label }
                    }

                    HStack(spacing: 14) {
                        field("Company") { TextField("Company", text: $company).textFieldStyle(.plain) }
                        field("Industry") { TextField("Industry", text: $industry).textFieldStyle(.plain) }
                    }

                    field("Title") { TextField("Role / title", text: $title).textFieldStyle(.plain) }

                    HStack(spacing: 14) {
                        field("Location") { TextField("City, Country", text: $location).textFieldStyle(.plain) }
                        field("Email") { TextField("name@example.com", text: $email).textFieldStyle(.plain) }
                    }

                    field("LinkedIn") { TextField("Profile URL", text: $linkedin).textFieldStyle(.plain) }

                    HStack(spacing: 14) {
                        picker("Closeness", selection: $closeness, options: NetworkCloseness.allCases) { $0.label }
                        picker("Keep in touch", selection: $followUpCadence,
                               options: [nil] + FollowUpCadence.allCases.map { Optional($0) }) { opt in
                            opt?.label ?? "Off"
                        }
                    }

                    if let e = entry {
                        keepInTouchStatusRow(for: e)
                    }

                    field("Notes") {
                        TextEditor(text: $notes)
                            .font(.system(size: 12))
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                    }

                    HStack {
                        if isEditing {
                            Button(role: .destructive) {
                                if let e = entry { Task { await appState.deleteNetworkEntry(e); onClose() } }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash").font(.system(size: 11))
                                    Text("Delete").font(.system(size: 12))
                                }
                                .foregroundStyle(Theme.Colors.red)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button { save() } label: {
                            Text(isEditing ? "Save" : "Create")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  && company.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 6)

                    if let e = entry {
                        dossierCard(for: e)
                        activityTimeline(for: e)
                    }

                    profileSection

                    if let e = entry {
                        EntryCompanyLinker(entryId: e.id, entryCompanyText: company)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(Theme.Colors.bg0)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let e = entry {
                name = e.name; type = e.type; company = e.company; industry = e.industry
                individualType = e.individualType; title = e.title
                location = e.location; email = e.email
                linkedin = e.linkedin ?? ""; closeness = e.closeness; notes = e.notes
                followUpCadence = e.followUpCadence

                // History + dossier: compute touchpoints once, then refresh
                // the AI summary in the background when it's gone stale.
                let index = ContactActivityIndex.build(
                    emails: appState.emails,
                    calendarEvents: appState.calendarEvents,
                    meetings: appState.meetings,
                    xDMs: appState.xDirectMessages,
                    xFollowers: appState.xFollowers
                )
                touchpoints = index.touchpoints(for: PersonIdentity(entry: e))
                dossier.refreshIfStale(entry: e, touchpoints: touchpoints, appState: appState)
            }
        }
    }

    // MARK: - Person 360: AI summary + activity timeline

    @ViewBuilder
    private func dossierCard(for stale: NetworkEntry) -> some View {
        let live = appState.networkEntries.first(where: { $0.id == stale.id }) ?? stale
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Relationship summary")
                    .hudLabel()
                Spacer()
                if dossier.generating.contains(live.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        dossier.generate(entry: live, touchpoints: touchpoints, appState: appState)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Regenerate summary")
                }
            }

            if let summary = live.aiSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let generated = live.aiSummaryGeneratedAt {
                    Text("generated \(generated.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            } else if dossier.generating.contains(live.id) {
                Text("Reading your history with \(live.name.isEmpty ? live.company : live.name)…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textDim)
            } else if let error = dossier.lastError[live.id] {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.amber)
            } else {
                Text("No summary yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .aiCardStyle()
    }

    @ViewBuilder
    private func activityTimeline(for entry: NetworkEntry) -> some View {
        if !touchpoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent activity")
                    .hudLabel()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(touchpoints.prefix(12).enumerated()), id: \.element.id) { index, touchpoint in
                        timelineRow(touchpoint, isFirst: index == 0)
                    }
                    if touchpoints.count > 12 {
                        Text("+ \(touchpoints.count - 12) earlier")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.top, 6)
                    }
                }
                .padding(10)
                .background(Theme.Colors.hoverTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ touchpoint: Touchpoint, isFirst: Bool) -> some View {
        let linkable = touchpoint.sourceType != nil && touchpoint.sourceId != nil
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst { OttoDivider().padding(.vertical, 5) }
            HStack(spacing: 8) {
                Image(systemName: touchpoint.kind.iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 14)
                Text(touchpoint.date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 46, alignment: .leading)
                Text(touchpoint.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if linkable {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let type = touchpoint.sourceType, let id = touchpoint.sourceId else { return }
                onClose()
                appState.locate(type: type, id: id)
            }
        }
    }

    /// Last-contact line + quick actions for the keep-in-touch loop. Reads
    /// the LIVE entry from AppState (not the editing copy) so "Mark
    /// contacted" and snoozes reflect immediately.
    @ViewBuilder
    private func keepInTouchStatusRow(for stale: NetworkEntry) -> some View {
        let live = appState.networkEntries.first(where: { $0.id == stale.id }) ?? stale
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "hand.wave")
                .font(.system(size: 11))
                .foregroundStyle(overdueTint(live))
            Text(lastContactLine(live))
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textDim)
            if let days = live.followUpOverdueDays() {
                Text(days == 0 ? "due today" : "\(days)d overdue")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(days >= 7 ? Theme.Colors.red : Theme.Colors.amber)
            } else if let snoozed = live.followUpSnoozedUntil, snoozed > Date() {
                Text("snoozed until \(snoozed.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            Spacer()
            Button {
                var updated = live
                updated.lastContactedAt = Date()
                updated.followUpSnoozedUntil = nil
                Task { await appState.updateNetworkEntry(updated) }
            } label: {
                Text("Mark contacted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.Colors.hoverTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func overdueTint(_ entry: NetworkEntry) -> Color {
        guard let days = entry.followUpOverdueDays() else { return Theme.Colors.textDim }
        return days >= 7 ? Theme.Colors.red : Theme.Colors.amber
    }

    private func lastContactLine(_ entry: NetworkEntry) -> String {
        guard let last = entry.lastContactedAt else { return "No contact on record" }
        let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
        let when = days == 0 ? "today" : (days == 1 ? "yesterday" : "\(days)d ago")
        return "Last contact \(when)"
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .hudLabel()
            content()
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Themed dropdown matching the app's filter menus (no native popup button).
    private func picker<T: Hashable>(
        _ label: String,
        selection: Binding<T>,
        options: [T],
        title: @escaping (T) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .hudLabel()
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button { selection.wrappedValue = opt } label: {
                        HStack {
                            Text(title(opt))
                            if selection.wrappedValue == opt { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title(selection.wrappedValue))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let trimmedLink = linkedin.trimmingCharacters(in: .whitespacesAndNewlines)
        if var e = entry {
            // Re-read the live row so quick actions taken while the sheet was
            // open (Mark contacted, snooze) aren't clobbered by this save.
            if let live = appState.networkEntries.first(where: { $0.id == e.id }) { e = live }
            e.name = name; e.type = type; e.company = company; e.industry = industry
            e.individualType = individualType; e.title = title
            e.location = location; e.email = email
            e.linkedin = trimmedLink.isEmpty ? nil : trimmedLink
            e.closeness = closeness; e.notes = notes
            e.followUpCadence = followUpCadence
            Task { await appState.updateNetworkEntry(e) }
        } else {
            let e = NetworkEntry(
                type: type, company: company, industry: industry, name: name,
                individualType: individualType, title: title,
                location: location, email: email,
                linkedin: trimmedLink.isEmpty ? nil : trimmedLink,
                closeness: closeness, notes: notes,
                followUpCadence: followUpCadence
            )
            Task { await appState.addNetworkEntry(e) }
        }
        onClose()
    }

    // MARK: - LinkedIn profile (read-only, structured sections)

    @ViewBuilder
    private var profileSection: some View {
        if let p = entry?.profile, !p.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("LinkedIn profile")
                        .hudLabel()
                    Spacer()
                }

                if !p.headline.isEmpty {
                    Text(p.headline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !p.location.isEmpty {
                    Label(p.location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                if !p.summary.isEmpty {
                    sectionLabel("Summary")
                    Text(p.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !p.experiences.isEmpty {
                    sectionLabel("Experience")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(p.experiences.indices, id: \.self) { i in
                            experienceCard(p.experiences[i])
                        }
                    }
                }

                if !p.education.isEmpty {
                    sectionLabel("Education")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(p.education.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                if !p.education[i].school.isEmpty {
                                    Text(p.education[i].school)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.Colors.text)
                                }
                                if !p.education[i].detail.isEmpty {
                                    Text(p.education[i].detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                            }
                        }
                    }
                }

                if !p.skills.isEmpty {
                    sectionLabel("Top Skills")
                    Text(p.skills.joined(separator: "  ·  "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !p.languages.isEmpty {
                    sectionLabel("Languages")
                    Text(p.languages.joined(separator: "  ·  "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !p.certifications.isEmpty {
                    sectionLabel("Certifications")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(p.certifications.indices, id: \.self) { i in
                            Text("•  " + p.certifications[i])
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Colors.border).frame(height: 1)
            }
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t)
            .hudLabel()
            .padding(.top, 2)
    }

    private func experienceCard(_ e: LinkedInExperience) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(e.title.isEmpty ? e.company : e.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.text)
            HStack(spacing: 6) {
                if !e.company.isEmpty && !e.title.isEmpty {
                    Text(e.company).font(.system(size: 11)).foregroundStyle(Theme.Colors.secondaryText)
                }
                if !e.dateRange.isEmpty {
                    Text((e.company.isEmpty || e.title.isEmpty ? "" : "·  ") + e.dateRange)
                        .font(Theme.Typography.monoSmall).foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            if !e.location.isEmpty {
                Text(e.location).font(.system(size: 10)).foregroundStyle(Theme.Colors.tertiaryText)
            }
            if !e.description.isEmpty {
                Text(e.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.Colors.hoverTint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

#Preview {
    NetworkHubListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}

// MARK: - Company linker (reverse side: link companies to a network entry)

/// Shown in a Network Hub entry's editor. Lists the companies this person is
/// linked to and lets you link/unlink — written straight to each Company's
/// `linkedNetworkEntryIds` (the same field the company side edits, so it's one
/// shared two-way link). Tapping a linked company opens its editor. With an
/// empty search it suggests companies whose name matches the entry's company.
private struct EntryCompanyLinker: View {
    let entryId: UUID
    let entryCompanyText: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var adding = false
    @State private var openCompany: Company?

    private var linked: [Company] {
        appState.companies.filter { $0.linkedNetworkEntryIds.contains(entryId) }
    }

    private var candidates: [Company] {
        let pool = appState.companies.filter { !$0.linkedNetworkEntryIds.contains(entryId) }
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let key = LocationNormalizer.fold(entryCompanyText)
            guard key.count >= 2 else { return [] }
            return Array(pool.filter {
                let n = LocationNormalizer.fold($0.name)
                return !n.isEmpty && (n.contains(key) || key.contains(n))
            }.prefix(8))
        }
        return Array(pool.filter { $0.searchableContent.localizedCaseInsensitiveContains(q) }.prefix(20))
    }

    private func link(_ c: Company) {
        guard !c.linkedNetworkEntryIds.contains(entryId) else { return }
        var u = c
        u.linkedNetworkEntryIds.append(entryId)
        Task { await appState.updateCompany(u) }
    }

    private func unlink(_ c: Company) {
        var u = c
        u.linkedNetworkEntryIds.removeAll { $0 == entryId }
        Task { await appState.updateCompany(u) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked companies")
                .hudLabel()

            if linked.isEmpty {
                Text("No companies linked yet.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Colors.tertiaryText)
            } else {
                ForEach(linked) { c in
                    HStack(spacing: 0) {
                        Button { openCompany = c } label: {
                            companyRowContent(c, trailingIcon: nil, trailingTint: .clear)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(c.name)")

                        Button { unlink(c) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Unlink")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.bg2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
            }

            Button { withAnimation { adding.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: adding ? "chevron.down" : "plus.circle").font(.system(size: 11))
                    Text(adding ? "Done" : "Link company").font(.system(size: 12))
                }
                .foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)

            if adding {
                TextField("Search companies…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.border, lineWidth: 1))
                if candidates.isEmpty {
                    Text(search.isEmpty ? "No name match — type to search all companies." : "No matches.")
                        .font(.system(size: 11)).foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(candidates) { c in
                            Button { link(c) } label: {
                                companyRowContent(c, trailingIcon: "plus", trailingTint: Theme.Colors.accentText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                }
            }
        }
        .sheet(item: $openCompany) { c in
            CompanyEditorSheet(company: appState.companies.first(where: { $0.id == c.id }) ?? c)
                .environment(appState)
        }
    }

    private func companyRowContent(_ c: Company, trailingIcon: String?, trailingTint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.type.icon)
                .font(.system(size: 11))
                .foregroundStyle(c.type == .unknown ? Theme.Colors.tertiaryText : c.type.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.text).lineLimit(1)
                let sub = [c.type.label, c.isCustomer ? "Customer" : "", c.formattedCommitment ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 10))
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
