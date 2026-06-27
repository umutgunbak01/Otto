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
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { company in
                            CompanyRow(company: company) {
                                editing = EditingTarget(id: company.id, company: company)
                            }
                            OttoDivider()
                        }
                    }
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
            HStack(alignment: .center) {
                Text("⬡ COMPANIES")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filtered.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                if totalCommitment > 0 {
                    Text("Σ \(Company.formatMoney(totalCommitment))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(Theme.Colors.green.opacity(0.4), lineWidth: 1))
                }

                Spacer()

                Button {
                    editing = EditingTarget(id: UUID(), company: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("New")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.Colors.hoverTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .frame(maxWidth: 260)

                // Customer filter
                Picker("", selection: $customerFilter) {
                    ForEach(CustomerFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

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
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Theme.Colors.accent.opacity(0.1) : Theme.Colors.borderSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(neon.opacity(isHovered ? 0.22 : 0.12))
                        .frame(width: 32, height: 32)
                        .shadow(color: neon.opacity(isHovered ? 0.7 : 0), radius: isHovered ? 8 : 0)
                    Image(systemName: company.type.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(neon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(company.name.isEmpty ? "Untitled" : company.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHovered ? neon : Theme.Colors.text)
                            .lineLimit(1)
                        if company.isCustomer {
                            Text("CUSTOMER")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(Theme.Colors.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Rectangle().stroke(Theme.Colors.green.opacity(0.5), lineWidth: 1))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(company.type.label)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        if !company.location.isEmpty {
                            Image(systemName: "mappin.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(company.location)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                }

                Spacer(minLength: 0)

                if let commitment = company.formattedCommitment {
                    Text(commitment)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.green)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(neon.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, Theme.Spacing.md)
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
