import SwiftUI

/// Full-width, tabbed, inline-editable table for a selected city. Switch across
/// All / Network / Connections / Companies / Events; each tab has its own
/// search, sort and filters, and every row edits in place (no detail sheet
/// needed) — the expand button still opens the full editor when wanted.
struct CityTableView: View {
    let group: CityGroup
    var onBack: () -> Void

    @State private var tab: CityTab = .all

    enum CityTab: String, CaseIterable, Identifiable {
        case all = "All", network = "Network", connections = "Connections"
        case companies = "Companies", events = "Events", communities = "Communities"
        var id: String { rawValue }
    }

    private func count(_ t: CityTab) -> Int {
        switch t {
        case .all: return group.totalCount
        case .network: return group.networkEntries.count
        case .connections: return group.connections.count
        case .companies: return group.companies.count
        case .events: return group.events.count
        case .communities: return group.communities.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            cityHeader
            tabBar
            OttoDivider()
            Group {
                switch tab {
                case .all:         CityAllTable(group: group)
                case .network:     CityNetworkTable(entries: group.networkEntries, city: group.displayName)
                case .connections: CityConnectionsTable(connections: group.connections, city: group.displayName)
                case .companies:   CityCompaniesTable(companies: group.companies, city: group.displayName)
                case .events:      CityEventsTable(events: group.events, city: group.displayName)
                case .communities: CityCommunitiesTable(communities: group.communities, city: group.displayName)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.bg0)
    }

    // MARK: - Header

    private var cityHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("MAP").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
                }
                .foregroundStyle(Theme.Colors.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(Theme.Colors.cyan.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Image(systemName: "mappin.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.Colors.cyan)
            Text(group.displayName)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Colors.text)
            Text("\(group.totalCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.Colors.borderSubtle)
                .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(CityTab.allCases) { t in
                let active = tab == t
                Button { tab = t } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                        Text("\(count(t))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(active ? Theme.Colors.cyan : Theme.Colors.tertiaryText)
                    }
                    .foregroundStyle(active ? Theme.Colors.cyan : Theme.Colors.textDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(active ? Theme.Colors.cyan.opacity(0.12) : Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(active ? Theme.Colors.cyan : .clear).frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

// MARK: - Table scaffold

/// Horizontally + vertically scrolling table shell with a sticky-styled header.
private struct InlineTable<Header: View, Rows: View>: View {
    let totalWidth: CGFloat
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(spacing: 0) {
                header()
                    .background(Theme.Colors.borderSubtle.opacity(0.7))
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border).frame(height: 1) }
                LazyVStack(spacing: 0) { rows() }
                // Breathing room so the last row can scroll clear of the dock's
                // floating suggestion chips (which overhang the content bottom).
                Color.clear.frame(height: 72)
            }
            .frame(width: totalWidth, alignment: .leading)
        }
    }
}

private struct CityEmpty: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .thin)).foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.Colors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Toolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) { content(); Spacer() }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
    }
}

// MARK: - Network table

private struct CityNetworkTable: View {
    let entries: [NetworkEntry]
    let city: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .closeness
    @State private var fType: NetworkType?
    @State private var fRole: IndividualType?
    @State private var fClose: NetworkCloseness?
    @State private var editingId: UUID?

    enum Sort: String, CaseIterable { case closeness = "Closeness", az = "A-Z", company = "Company", type = "Type" }
    private enum C { static let open: CGFloat = 32, name: CGFloat = 180, type: CGFloat = 130, role: CGFloat = 125, company: CGFloat = 155, title: CGFloat = 165, close: CGFloat = 160
        static var total: CGFloat { open + name + type + role + company + title + close } }

    private var rows: [NetworkEntry] {
        var r = entries
        if !search.isEmpty { r = r.filter { $0.searchableContent.localizedCaseInsensitiveContains(search) } }
        if let t = fType { r = r.filter { $0.type == t } }
        if let it = fRole { r = r.filter { $0.individualType == it } }
        if let c = fClose { r = r.filter { $0.closeness == c } }
        switch sort {
        case .az: r.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .company: r.sort { $0.company.lowercased() < $1.company.lowercased() }
        case .type: r.sort { $0.type.label < $1.type.label }
        case .closeness: r.sort { $0.closeness.rank == $1.closeness.rank ? $0.name.lowercased() < $1.name.lowercased() : $0.closeness.rank > $1.closeness.rank }
        }
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search network…")
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fType = nil } label: { Text("All Types") }
                    Divider()
                    ForEach(NetworkType.allCases, id: \.self) { t in Button { fType = t } label: { Label(t.label, systemImage: t.icon) } }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: fType?.label ?? "Type", isActive: fType != nil) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fRole = nil } label: { Text("All Roles") }
                    Divider()
                    ForEach(IndividualType.allCases, id: \.self) { it in Button { fRole = it } label: { Label(it.label, systemImage: it.icon) } }
                } label: { TableFilterChip(icon: "person.crop.rectangle", text: fRole?.label ?? "Role", isActive: fRole != nil) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fClose = nil } label: { Text("All") }
                    Divider()
                    ForEach(NetworkCloseness.allCases, id: \.self) { c in Button { fClose = c } label: { Label(c.label, systemImage: c.icon) } }
                } label: { TableFilterChip(icon: "heart.circle", text: fClose?.label ?? "Closeness", isActive: fClose != nil) }.menuStyle(.borderlessButton)
            }
            if rows.isEmpty {
                CityEmpty(icon: ContentType.networkHub.iconName, text: "No network entries in \(city)")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "NAME", width: C.name)
                        TableHeaderCell(title: "TYPE", width: C.type)
                        TableHeaderCell(title: "ROLE", width: C.role)
                        TableHeaderCell(title: "COMPANY", width: C.company)
                        TableHeaderCell(title: "TITLE", width: C.title)
                        TableHeaderCell(title: "CLOSENESS", width: C.close)
                    }
                } rows: {
                    ForEach(rows) { e in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open, tint: e.profile != nil ? ContentType.networkHub.color : Theme.Colors.tertiaryText) { editingId = e.id }
                            InlineTextCell(text: e.name, width: C.name, placeholder: "Name", bold: true) { v in commit(e) { $0.name = v } }
                            InlineEnumCell(width: C.type, value: e.type, options: NetworkType.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit(e) { $0.type = v } }
                            InlineEnumCell(width: C.role, value: e.individualType, options: IndividualType.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit(e) { $0.individualType = v } }
                            InlineTextCell(text: e.company, width: C.company) { v in commit(e) { $0.company = v } }
                            InlineTextCell(text: e.title, width: C.title) { v in commit(e) { $0.title = v } }
                            InlineEnumCell(width: C.close, value: e.closeness, options: NetworkCloseness.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit(e) { $0.closeness = v } }
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { editingId.map(IDItem.init) }, set: { editingId = $0?.id })) { item in
            NetworkEntryEditor(entry: appState.networkEntries.first { $0.id == item.id }, onClose: { editingId = nil })
                .environment(appState).frame(minWidth: 600, minHeight: 640)
        }
    }

    private func commit(_ e: NetworkEntry, _ mutate: (inout NetworkEntry) -> Void) {
        var u = e; mutate(&u); Task { await appState.updateNetworkEntry(u) }
    }
}

// MARK: - Connections table

private struct CityConnectionsTable: View {
    let connections: [Connection]
    let city: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .az
    @State private var fCategory: ConnectionCategory?
    @State private var fClose: ConnectionCloseness?
    @State private var editingId: UUID?

    enum Sort: String, CaseIterable { case az = "A-Z", company = "Company", closeness = "Closeness" }
    private enum C { static let open: CGFloat = 32, first: CGFloat = 130, last: CGFloat = 130, headline: CGFloat = 220, company: CGFloat = 150, close: CGFloat = 150, cat: CGFloat = 150
        static var total: CGFloat { open + first + last + headline + company + close + cat } }

    private var rows: [Connection] {
        var r = connections
        if !search.isEmpty { r = r.filter { $0.searchableContent.localizedCaseInsensitiveContains(search) } }
        if let c = fCategory { r = r.filter { $0.category == c } }
        if let cl = fClose { r = r.filter { $0.closeness == cl } }
        switch sort {
        case .az: r.sort { $0.fullName.lowercased() < $1.fullName.lowercased() }
        case .company: r.sort { $0.company.lowercased() < $1.company.lowercased() }
        case .closeness: r.sort { closenessRank($0.closeness) > closenessRank($1.closeness) }
        }
        return r
    }
    private func closenessRank(_ c: ConnectionCloseness) -> Int { switch c { case .close: 3; case .friendly: 2; case .acquaintance: 1; case .unknown: 0 } }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search people…")
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fCategory = nil } label: { Text("All Categories") }
                    Divider()
                    ForEach(ConnectionCategory.allCases, id: \.self) { c in Button { fCategory = c } label: { Label(c.label, systemImage: c.icon) } }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: fCategory?.label ?? "Category", isActive: fCategory != nil) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fClose = nil } label: { Text("All") }
                    Divider()
                    ForEach(ConnectionCloseness.allCases, id: \.self) { c in Button { fClose = c } label: { Label(c.label, systemImage: c.icon) } }
                } label: { TableFilterChip(icon: "heart.circle", text: fClose?.label ?? "Closeness", isActive: fClose != nil) }.menuStyle(.borderlessButton)
            }
            if rows.isEmpty {
                CityEmpty(icon: "person.2", text: "No LinkedIn connections in \(city)")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "FIRST", width: C.first)
                        TableHeaderCell(title: "LAST", width: C.last)
                        TableHeaderCell(title: "HEADLINE", width: C.headline)
                        TableHeaderCell(title: "COMPANY", width: C.company)
                        TableHeaderCell(title: "CLOSENESS", width: C.close)
                        TableHeaderCell(title: "CATEGORY", width: C.cat)
                    }
                } rows: {
                    ForEach(rows) { c in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open) { editingId = c.id }
                            InlineTextCell(text: c.firstName, width: C.first, placeholder: "First", bold: true) { v in commit(c) { $0.firstName = v } }
                            InlineTextCell(text: c.lastName, width: C.last) { v in commit(c) { $0.lastName = v } }
                            InlineTextCell(text: c.headline, width: C.headline) { v in commit(c) { $0.headline = v } }
                            InlineTextCell(text: c.company, width: C.company) { v in commit(c) { $0.company = v } }
                            InlineEnumCell(width: C.close, value: c.closeness, options: ConnectionCloseness.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit(c) { $0.closeness = v } }
                            InlineEnumCell(width: C.cat, value: c.category, options: ConnectionCategory.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit(c) { $0.category = v } }
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { editingId.map(IDItem.init) }, set: { editingId = $0?.id })) { item in
            if let c = appState.connections.first(where: { $0.id == item.id }) {
                ConnectionDetailView(connection: c, onClose: { editingId = nil })
                    .environment(appState).frame(minWidth: 560, minHeight: 640)
            }
        }
    }

    private func commit(_ c: Connection, _ mutate: (inout Connection) -> Void) {
        var u = c; mutate(&u); Task { await appState.updateConnection(u) }
    }
}

// MARK: - Companies table

private struct CityCompaniesTable: View {
    let companies: [Company]
    let city: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var fType: CompanyType?
    @State private var customer: Customer = .all
    @State private var editingCompany: Company?

    enum Sort: String, CaseIterable { case name = "Name", commitment = "Commitment", recent = "Recent" }
    enum Customer: String, CaseIterable { case all = "All", customers = "Customers", prospects = "Prospects" }
    private enum C { static let open: CGFloat = 32, name: CGFloat = 190, type: CGFloat = 145, cust: CGFloat = 115, commit: CGFloat = 120, web: CGFloat = 190, notes: CGFloat = 240
        static var total: CGFloat { open + name + type + cust + commit + web + notes } }

    private var rows: [Company] {
        var r = companies
        if !search.isEmpty { r = r.filter { $0.searchableContent.localizedCaseInsensitiveContains(search) } }
        if let t = fType { r = r.filter { $0.type == t } }
        switch customer { case .all: break; case .customers: r = r.filter { $0.isCustomer }; case .prospects: r = r.filter { !$0.isCustomer } }
        switch sort {
        case .name: r.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .commitment: r.sort { ($0.commitmentAmount ?? 0) > ($1.commitmentAmount ?? 0) }
        case .recent: r.sort { $0.updatedAt > $1.updatedAt }
        }
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search companies…")
                Picker("", selection: $customer) { ForEach(Customer.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 210)
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fType = nil } label: { Text("All Types") }
                    Divider()
                    ForEach(CompanyType.allCases) { t in Button { fType = t } label: { Label(t.label, systemImage: t.icon) } }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: fType?.label ?? "Type", isActive: fType != nil) }.menuStyle(.borderlessButton)
            }
            if rows.isEmpty {
                CityEmpty(icon: "building.2", text: "No companies in \(city)")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "NAME", width: C.name)
                        TableHeaderCell(title: "TYPE", width: C.type)
                        TableHeaderCell(title: "CUSTOMER", width: C.cust)
                        TableHeaderCell(title: "COMMITMENT", width: C.commit)
                        TableHeaderCell(title: "WEBSITE", width: C.web)
                        TableHeaderCell(title: "NOTES", width: C.notes)
                    }
                } rows: {
                    ForEach(rows) { co in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open) { editingCompany = co }
                            InlineTextCell(text: co.name, width: C.name, placeholder: "Name", bold: true) { v in commit(co) { $0.name = v } }
                            InlineEnumCell(width: C.type, value: co.type, options: CompanyType.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit(co) { $0.type = v } }
                            InlineToggleCell(isOn: co.isCustomer, width: C.cust, onText: "Customer") { v in commit(co) { $0.isCustomer = v } }
                            InlineMoneyCell(amount: co.commitmentAmount, width: C.commit) { v in commit(co) { $0.commitmentAmount = v } }
                            InlineTextCell(text: co.website ?? "", width: C.web, placeholder: "—", tint: Theme.Colors.cyanDim) { v in commit(co) { $0.website = v.isEmpty ? nil : v } }
                            InlineTextCell(text: co.notes, width: C.notes) { v in commit(co) { $0.notes = v } }
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: $editingCompany) { co in
            CompanyEditorSheet(company: co).environment(appState)
        }
    }

    private func commit(_ co: Company, _ mutate: (inout Company) -> Void) {
        var u = co; mutate(&u); Task { await appState.updateCompany(u) }
    }
}

// MARK: - Events table

private struct CityEventsTable: View {
    let events: [Event]
    let city: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .date
    @State private var fType: EventType?
    @State private var fStatus: EventStatus?
    @State private var editingEvent: Event?

    enum Sort: String, CaseIterable { case date = "Date", name = "Name", recent = "Recent" }
    private enum C { static let open: CGFloat = 32, name: CGFloat = 190, type: CGFloat = 135, status: CGFloat = 140, start: CGFloat = 135, end: CGFloat = 135, budget: CGFloat = 110, notes: CGFloat = 220
        static var total: CGFloat { open + name + type + status + start + end + budget + notes } }

    private var rows: [Event] {
        var r = events
        if !search.isEmpty { r = r.filter { $0.searchableContent.localizedCaseInsensitiveContains(search) } }
        if let t = fType { r = r.filter { $0.type == t } }
        if let s = fStatus { r = r.filter { $0.status == s } }
        switch sort {
        case .date: r.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        case .name: r.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .recent: r.sort { $0.updatedAt > $1.updatedAt }
        }
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search events…")
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fStatus = nil } label: { Text("All") }
                    Divider()
                    ForEach(EventStatus.allCases) { s in Button { fStatus = s } label: { Label(s.label, systemImage: s.icon) } }
                } label: { TableFilterChip(icon: "flag", text: fStatus?.label ?? "Status", isActive: fStatus != nil) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fType = nil } label: { Text("All Types") }
                    Divider()
                    ForEach(EventType.allCases) { t in Button { fType = t } label: { Label(t.label, systemImage: t.icon) } }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: fType?.label ?? "Type", isActive: fType != nil) }.menuStyle(.borderlessButton)
            }
            if rows.isEmpty {
                CityEmpty(icon: "calendar", text: "No events in \(city)")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "NAME", width: C.name)
                        TableHeaderCell(title: "TYPE", width: C.type)
                        TableHeaderCell(title: "STATUS", width: C.status)
                        TableHeaderCell(title: "START", width: C.start)
                        TableHeaderCell(title: "END", width: C.end)
                        TableHeaderCell(title: "BUDGET", width: C.budget)
                        TableHeaderCell(title: "NOTES", width: C.notes)
                    }
                } rows: {
                    ForEach(rows) { ev in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open) { editingEvent = ev }
                            InlineTextCell(text: ev.name, width: C.name, placeholder: "Name", bold: true) { v in commit(ev) { $0.name = v } }
                            InlineEnumCell(width: C.type, value: ev.type, options: EventType.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0 == .unknown ? Theme.Colors.tertiaryText : $0.color }) { v in commit(ev) { $0.type = v } }
                            InlineEnumCell(width: C.status, value: ev.status, options: EventStatus.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit(ev) { $0.status = v } }
                            InlineDateCell(date: ev.startDate, width: C.start) { v in commit(ev) { $0.startDate = v } }
                            InlineDateCell(date: ev.endDate, width: C.end) { v in commit(ev) { $0.endDate = v } }
                            InlineMoneyCell(amount: ev.budgetAmount, width: C.budget, tint: Theme.Colors.amber) { v in commit(ev) { $0.budgetAmount = v } }
                            InlineTextCell(text: ev.notes, width: C.notes) { v in commit(ev) { $0.notes = v } }
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: $editingEvent) { ev in
            EventEditorSheet(event: ev).environment(appState)
        }
    }

    private func commit(_ ev: Event, _ mutate: (inout Event) -> Void) {
        var u = ev; mutate(&u); Task { await appState.updateEvent(u) }
    }
}

// MARK: - Communities table

private struct CityCommunitiesTable: View {
    let communities: [Community]
    let city: String
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .name
    @State private var fType: CommunityType?
    @State private var perkOnly = false
    @State private var editingCommunity: Community?

    enum Sort: String, CaseIterable { case name = "Name", recent = "Recent", type = "Type" }
    private enum C { static let open: CGFloat = 32, name: CGFloat = 200, type: CGFloat = 145, perk: CGFloat = 110, url: CGFloat = 190, notes: CGFloat = 260
        static var total: CGFloat { open + name + type + perk + url + notes } }

    private var rows: [Community] {
        var r = communities
        if !search.isEmpty { r = r.filter { $0.searchableContent.localizedCaseInsensitiveContains(search) } }
        if let t = fType { r = r.filter { $0.type == t } }
        if perkOnly { r = r.filter { $0.builderSupportPerk } }
        switch sort {
        case .name: r.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .recent: r.sort { $0.updatedAt > $1.updatedAt }
        case .type: r.sort { $0.type.label < $1.type.label }
        }
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search communities…")
                Button { perkOnly.toggle() } label: { TableFilterChip(icon: "gift", text: "Builder Perk", isActive: perkOnly) }.buttonStyle(.plain)
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
                Menu {
                    Button { fType = nil } label: { Text("All Types") }
                    Divider()
                    ForEach(CommunityType.allCases) { t in Button { fType = t } label: { Label(t.label, systemImage: t.icon) } }
                } label: { TableFilterChip(icon: "square.grid.2x2", text: fType?.label ?? "Type", isActive: fType != nil) }.menuStyle(.borderlessButton)
            }
            if rows.isEmpty {
                CityEmpty(icon: "person.3", text: "No communities in \(city)")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "NAME", width: C.name)
                        TableHeaderCell(title: "TYPE", width: C.type)
                        TableHeaderCell(title: "PERK", width: C.perk)
                        TableHeaderCell(title: "URL", width: C.url)
                        TableHeaderCell(title: "NOTES", width: C.notes)
                    }
                } rows: {
                    ForEach(rows) { cm in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open) { editingCommunity = cm }
                            InlineTextCell(text: cm.name, width: C.name, placeholder: "Name", bold: true) { v in commit(cm) { $0.name = v } }
                            InlineEnumCell(width: C.type, value: cm.type, options: CommunityType.allCases, title: { $0.label }, icon: { $0.icon }, color: { $0.color }) { v in commit(cm) { $0.type = v } }
                            InlineToggleCell(isOn: cm.builderSupportPerk, width: C.perk, onText: "Perk") { v in commit(cm) { $0.builderSupportPerk = v } }
                            InlineTextCell(text: cm.url ?? "", width: C.url, placeholder: "—", tint: Theme.Colors.cyanDim) { v in commit(cm) { $0.url = v.isEmpty ? nil : v } }
                            InlineTextCell(text: cm.notes, width: C.notes) { v in commit(cm) { $0.notes = v } }
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: $editingCommunity) { cm in
            CommunityEditorSheet(community: cm).environment(appState)
        }
    }

    private func commit(_ cm: Community, _ mutate: (inout Community) -> Void) {
        var u = cm; mutate(&u); Task { await appState.updateCommunity(u) }
    }
}

// MARK: - "All" overview table

private struct CityAllTable: View {
    let group: CityGroup
    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var sort: Sort = .kind
    @State private var editing: CityItem?

    enum Sort: String, CaseIterable { case kind = "Kind", az = "A-Z" }
    private enum C { static let open: CGFloat = 32, kind: CGFloat = 120, name: CGFloat = 210, detail: CGFloat = 280, tag: CGFloat = 180
        static var total: CGFloat { open + kind + name + detail + tag } }

    private var items: [CityItem] {
        var all: [CityItem] = []
        all += group.networkEntries.map(CityItem.network)
        all += group.connections.map(CityItem.connection)
        all += group.companies.map(CityItem.company)
        all += group.events.map(CityItem.event)
        all += group.communities.map(CityItem.community)
        if !search.isEmpty { all = all.filter { $0.searchText.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .az: all.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .kind: all.sort { $0.kindRank == $1.kindRank ? $0.name.lowercased() < $1.name.lowercased() : $0.kindRank < $1.kindRank }
        }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                TableSearchField(text: $search, placeholder: "Search everything…")
                Menu { ForEach(Sort.allCases, id: \.self) { o in Button { sort = o } label: { Label(o.rawValue, systemImage: sort == o ? "checkmark" : "") } } }
                    label: { TableFilterChip(icon: "arrow.up.arrow.down", text: sort.rawValue, isActive: false) }.menuStyle(.borderlessButton)
            }
            if items.isEmpty {
                CityEmpty(icon: "tray", text: "Nothing here yet")
            } else {
                InlineTable(totalWidth: C.total) {
                    HStack(spacing: 0) {
                        TableHeaderCell(title: "", width: C.open)
                        TableHeaderCell(title: "KIND", width: C.kind)
                        TableHeaderCell(title: "NAME", width: C.name)
                        TableHeaderCell(title: "DETAIL", width: C.detail)
                        TableHeaderCell(title: "RELATIONSHIP", width: C.tag)
                    }
                } rows: {
                    ForEach(items) { item in
                        HStack(spacing: 0) {
                            OpenRowCell(width: C.open, tint: item.color) { editing = item }
                            InlineBadgeCell(icon: item.kindIcon, text: item.kindLabel, color: item.color, width: C.kind)
                            InlineTextCell(text: item.name, width: C.name, bold: true) { v in item.commitName(v, appState) }
                            InlineBadgeCell(icon: "text.alignleft", text: item.detail, color: Theme.Colors.textDim, width: C.detail)
                            InlineBadgeCell(icon: item.tagIcon, text: item.tag, color: item.tagColor, width: C.tag)
                        }
                        .frame(height: TableMetrics.rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.border.opacity(0.35)).frame(height: 1) }
                    }
                }
            }
        }
        .sheet(item: $editing) { item in
            item.editor(appState) { editing = nil }
        }
    }
}

// MARK: - Helpers

/// Identifiable wrapper so a bare UUID can drive `.sheet(item:)`.
private struct IDItem: Identifiable { let id: UUID }

/// Unified row for the "All" tab.
private enum CityItem: Identifiable {
    case network(NetworkEntry), connection(Connection), company(Company), event(Event), community(Community)

    var id: String {
        switch self {
        case .network(let e): return "n-\(e.id)"
        case .connection(let c): return "c-\(c.id)"
        case .company(let co): return "o-\(co.id)"
        case .event(let ev): return "e-\(ev.id)"
        case .community(let cm): return "m-\(cm.id)"
        }
    }
    var kindRank: Int { switch self { case .network: 0; case .connection: 1; case .company: 2; case .event: 3; case .community: 4 } }
    var kindLabel: String { switch self { case .network: "Network"; case .connection: "Person"; case .company: "Company"; case .event: "Event"; case .community: "Community" } }
    var kindIcon: String { switch self {
        case .network: ContentType.networkHub.iconName; case .connection: "person.fill"
        case .company: "building.2.fill"; case .event: "calendar"; case .community: "person.3.fill" } }
    var color: Color { switch self {
        case .network: ContentType.networkHub.color; case .connection: ContentType.connection.color
        case .company: ContentType.company.color; case .event: ContentType.event.color
        case .community: ContentType.community.color } }
    var name: String { switch self {
        case .network(let e): e.name; case .connection(let c): c.fullName
        case .company(let co): co.name; case .event(let ev): ev.name; case .community(let cm): cm.name } }
    var detail: String { switch self {
        case .network(let e): e.displayInfo
        case .connection(let c): c.displayInfo
        case .company(let co): co.type.label
        case .event(let ev): [ev.type.label, ev.dateRangeText].filter { !$0.isEmpty }.joined(separator: " · ")
        case .community(let cm): cm.type.label } }
    var tag: String { switch self {
        case .network(let e): e.closeness.label
        case .connection(let c): c.closeness.label
        case .company(let co): co.isCustomer ? "Customer" : "Prospect"
        case .event(let ev): ev.status.label
        case .community(let cm): cm.builderSupportPerk ? "Builder Perk" : "—" } }
    var tagIcon: String { switch self {
        case .network(let e): e.closeness.icon
        case .connection(let c): c.closeness.icon
        case .company(let co): co.isCustomer ? "checkmark.seal.fill" : "circle"
        case .event(let ev): ev.status.icon
        case .community(let cm): cm.builderSupportPerk ? "gift.fill" : "circle" } }
    var tagColor: Color { switch self {
        case .network(let e): e.closeness == .unknown ? Theme.Colors.tertiaryText : e.closeness.color
        case .connection(let c): c.closeness == .unknown ? Theme.Colors.tertiaryText : c.closeness.color
        case .company(let co): co.isCustomer ? Theme.Colors.green : Theme.Colors.tertiaryText
        case .event(let ev): ev.status.color
        case .community(let cm): cm.builderSupportPerk ? Theme.Colors.amber : Theme.Colors.tertiaryText } }
    var searchText: String { switch self {
        case .network(let e): e.searchableContent; case .connection(let c): c.searchableContent
        case .company(let co): co.searchableContent; case .event(let ev): ev.searchableContent
        case .community(let cm): cm.searchableContent } }

    func commitName(_ v: String, _ appState: AppState) {
        switch self {
        case .network(let e): var u = e; u.name = v; Task { await appState.updateNetworkEntry(u) }
        case .connection(let c):
            var u = c
            let parts = v.split(separator: " ", maxSplits: 1).map(String.init)
            u.firstName = parts.first ?? v
            u.lastName = parts.count > 1 ? parts[1] : ""
            Task { await appState.updateConnection(u) }
        case .company(let co): var u = co; u.name = v; Task { await appState.updateCompany(u) }
        case .event(let ev): var u = ev; u.name = v; Task { await appState.updateEvent(u) }
        case .community(let cm): var u = cm; u.name = v; Task { await appState.updateCommunity(u) }
        }
    }

    @ViewBuilder
    func editor(_ appState: AppState, onClose: @escaping () -> Void) -> some View {
        switch self {
        case .network(let e):
            NetworkEntryEditor(entry: e, onClose: onClose).environment(appState).frame(minWidth: 600, minHeight: 640)
        case .connection(let c):
            ConnectionDetailView(connection: c, onClose: onClose).environment(appState).frame(minWidth: 560, minHeight: 640)
        case .company(let co):
            CompanyEditorSheet(company: co).environment(appState)
        case .event(let ev):
            EventEditorSheet(event: ev).environment(appState)
        case .community(let cm):
            CommunityEditorSheet(community: cm).environment(appState)
        }
    }
}
