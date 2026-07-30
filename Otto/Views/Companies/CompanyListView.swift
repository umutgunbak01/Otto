import SwiftUI

struct CompanyListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = .recent
    @State private var filterType: CompanyType? = nil
    @State private var customerFilter: CustomerFilter = .all
    @State private var editing: EditingTarget?

    enum SortOption: String, CaseIterable {
        case recent = "Recent"
        case name = "Name"
        case commitment = "Commitment"
    }

    enum CustomerFilter: String, CaseIterable {
        case all = "All"
        case customers = "Customers"
        case prospects = "Prospects"
    }

    /// Wraps either a new (nil id) or existing company for the editor sheet.
    struct EditingTarget: Identifiable {
        let id: UUID
        let company: Company?
    }

    var filtered: [Company] {
        var result = appState.companies

        if !searchText.isEmpty {
            result = result.filter { $0.searchableContent.localizedCaseInsensitiveContains(searchText) }
        }
        if let type = filterType {
            result = result.filter { $0.type == type }
        }
        switch customerFilter {
        case .all: break
        case .customers: result = result.filter { $0.isCustomer }
        case .prospects: result = result.filter { !$0.isCustomer }
        }

        switch sortOption {
        case .recent:
            result.sort { $0.updatedAt > $1.updatedAt }
        case .name:
            result.sort { $0.name.lowercased() < $1.name.lowercased() }
        case .commitment:
            result.sort { ($0.commitmentAmount ?? 0) > ($1.commitmentAmount ?? 0) }
        }
        return result
    }

    private var totalCommitment: Double {
        appState.companies.filter { $0.isCustomer }.compactMap { $0.commitmentAmount }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            viewbar
            if appState.companies.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { company in
                            CompanyRow(company: company) {
                                editing = EditingTarget(id: company.id, company: company)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xxl)
                    .frame(maxWidth: 828)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $editing) { target in
            CompanyEditorSheet(company: target.company)
                .environment(appState)
        }
    }

    // MARK: - Viewbar

    private var viewbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Companies")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(filtered.count)")

            if totalCommitment > 0 {
                Text("Σ \(Company.formatMoney(totalCommitment)) committed")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(Theme.Colors.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Theme.Colors.tintGreen))
                    .overlay(Capsule().strokeBorder(Theme.Colors.green.opacity(0.2), lineWidth: 1))
                    .lineLimit(1)
                    .fixedSize()
            }

            OttoPillRail(
                options: CustomerFilter.allCases.map { (value: $0, label: $0.rawValue) },
                selection: $customerFilter
            )

            Spacer(minLength: 8)

            // Type filter
            Menu {
                Button { filterType = nil } label: {
                    HStack { Text("All Types"); if filterType == nil { Image(systemName: "checkmark") } }
                }
                Divider()
                ForEach(CompanyType.allCases) { type in
                    Button { filterType = type } label: {
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.label)
                            if filterType == type { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                OttoBarButtonLabel(label: filterType?.label ?? "Type", showsCaret: true)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif

            // Sort
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
            #endif

            OttoSearchMini(placeholder: "Search", text: $searchText)

            OttoNewButton(label: "New") {
                editing = EditingTarget(id: UUID(), company: nil)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "building.2",
            title: "No companies yet",
            message: "Track customers, prospects and partners — commitments, cities, and the people you know at each."
        ) {
            OttoSuggestionChip(systemImage: "plus", label: "Add a company") {
                editing = EditingTarget(id: UUID(), company: nil)
            }
        }
    }

    private var noResultsState: some View {
        OttoEmptyState(
            systemImage: "magnifyingglass",
            title: "No matches",
            message: "Nothing fits the current search and filters."
        ) {
            OttoSuggestionChip(systemImage: "arrow.counterclockwise", label: "Clear filters") {
                searchText = ""; filterType = nil; customerFilter = .all
            }
        }
    }
}

// MARK: - Company Row

private struct CompanyRow: View {
    let company: Company
    let onOpen: () -> Void
    @State private var isHovered = false

    /// Stable per-company square tint — the name hashes into the redesign's
    /// five accents so a given company keeps its color across launches.
    private static let palette: [Color] = [
        Theme.Colors.green, Theme.Colors.violet, Theme.Colors.amber,
        Theme.Colors.cyan, Theme.Colors.blue,
    ]

    private var squareColor: Color {
        var hash: UInt64 = 1469598103934665603
        for byte in company.name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                OttoSquare(systemImage: "building.2", color: squareColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(company.name.isEmpty ? "Untitled" : company.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(company.type.label)
                        if !company.location.isEmpty {
                            Image(systemName: "mappin")
                                .font(.system(size: 11))
                            Text(company.location)
                                .lineLimit(1)
                        }
                        if !company.linkedNetworkEntryIds.isEmpty {
                            Text("· \(company.linkedNetworkEntryIds.count) linked")
                                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                .help("\(company.linkedNetworkEntryIds.count) linked Network Hub people")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer(minLength: 12)

                statusChip

                if let commitment = company.formattedCommitment {
                    Text(commitment)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.green)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // Quiet list row — no border, wash on hover.
            RoundedRectangle(cornerRadius: 11)
                .fill(isHovered ? Theme.Colors.panel : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var statusChip: some View {
        Text(company.isCustomer ? "Customer" : "Prospect")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(company.isCustomer ? Theme.Colors.green : Theme.Colors.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(company.isCustomer ? Theme.Colors.tintGreen : Theme.Colors.tintAmber))
            .overlay(
                Capsule().strokeBorder(
                    (company.isCustomer ? Theme.Colors.green : Theme.Colors.amber).opacity(0.2),
                    lineWidth: 1
                )
            )
    }
}

#Preview {
    CompanyListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
