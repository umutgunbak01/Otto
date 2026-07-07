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
            header
            OttoDivider()
            if appState.companies.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noResultsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { company in
                            CompanyRow(company: company) {
                                editing = EditingTarget(id: company.id, company: company)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.lg)
                }
            }
        }
        .sheet(item: $editing) { target in
            CompanyEditorSheet(company: target.company)
                .environment(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: 10) {
                Text("Companies")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)

                OttoCountBadge(count: filtered.count)

                if totalCommitment > 0 {
                    Text("Σ \(Company.formatMoney(totalCommitment))")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.Colors.tintGreen)
                        )
                }

                Spacer()

                Button {
                    editing = EditingTarget(id: UUID(), company: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("New")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(AccentButtonStyle())
            }

            HStack(spacing: Theme.Spacing.sm) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Colors.bgInput)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
                .frame(maxWidth: 260)

                // Customer filter
                HStack(spacing: 3) {
                    ForEach(CustomerFilter.allCases, id: \.self) { option in
                        Button { customerFilter = option } label: {
                            Text(option.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(customerFilter == option ? Theme.Colors.accentText : Theme.Colors.textDim)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(customerFilter == option ? Theme.Colors.selectTint : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

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
                    filterChipLabel(icon: "square.grid.2x2", text: filterType?.label ?? "Type", isActive: filterType != nil)
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
                    filterChipLabel(icon: "arrow.up.arrow.down", text: sortOption.rawValue, isActive: false)
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif

                Spacer()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    private func filterChipLabel(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.textDim)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Theme.Colors.selectTint : Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isActive ? Color.clear : Theme.Colors.border, lineWidth: 1)
        )
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.2")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))
            Text("No companies yet")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Button { editing = EditingTarget(id: UUID(), company: nil) } label: {
                Text("Add a company")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.accent)
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
            Text("No results")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Button {
                searchText = ""; filterType = nil; customerFilter = .all
            } label: {
                Text("Clear filters").font(.system(size: 13)).foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Company Row

private struct CompanyRow: View {
    let company: Company
    let onOpen: () -> Void
    @State private var isHovered = false

    private var neon: Color { company.type == .unknown ? ContentType.company.color : company.type.color }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(neon.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: company.type.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(neon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(company.name.isEmpty ? "Untitled" : company.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(company.type.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textDim)
                        if !company.location.isEmpty {
                            Image(systemName: "mappin.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textDim)
                            Text(company.location)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.textDim)
                                .lineLimit(1)
                        }
                        if !company.linkedNetworkEntryIds.isEmpty {
                            Text("· \(company.linkedNetworkEntryIds.count) linked")
                                .font(Theme.Typography.monoCaption)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .help("\(company.linkedNetworkEntryIds.count) linked Network Hub people")
                        }
                    }
                }

                Spacer(minLength: 0)

                Text(company.isCustomer ? "Customer" : "Prospect")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(company.isCustomer ? Theme.Colors.green : Theme.Colors.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(company.isCustomer ? Theme.Colors.tintGreen : Theme.Colors.tintAmber)
                    )

                if let commitment = company.formattedCommitment {
                    Text(commitment)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.green)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isHovered ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

#Preview {
    CompanyListView()
        .environment(AppState())
        .frame(width: 1000, height: 700)
}
