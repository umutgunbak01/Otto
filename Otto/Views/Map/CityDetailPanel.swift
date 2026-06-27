import SwiftUI

/// Side panel listing everyone/everything you know in one city. Shown when a
/// map pin is selected. Rows call back to open the relevant detail/editor.
struct CityDetailPanel: View {
    let group: CityGroup
    var onClose: () -> Void
    var onSelectConnection: (Connection) -> Void
    var onSelectCompany: (Company) -> Void
    var onSelectEvent: (Event) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if !group.events.isEmpty {
                        section(title: "EVENTS", count: group.events.count, color: ContentType.event.color) {
                            ForEach(group.events) { event in
                                rowButton(
                                    icon: event.type.icon,
                                    tint: event.type == .unknown ? ContentType.event.color : event.type.color,
                                    title: event.name,
                                    subtitle: [event.status.label, event.dateRangeText]
                                        .filter { !$0.isEmpty }.joined(separator: " · ")
                                ) { onSelectEvent(event) }
                            }
                        }
                    }

                    if !group.companies.isEmpty {
                        section(title: "COMPANIES", count: group.companies.count, color: ContentType.company.color) {
                            ForEach(group.companies) { company in
                                rowButton(
                                    icon: company.type.icon,
                                    tint: company.type == .unknown ? ContentType.company.color : company.type.color,
                                    title: company.name,
                                    subtitle: [company.isCustomer ? "Customer" : company.type.label,
                                               company.formattedCommitment ?? ""]
                                        .filter { !$0.isEmpty }.joined(separator: " · ")
                                ) { onSelectCompany(company) }
                            }
                        }
                    }

                    if !group.connections.isEmpty {
                        section(title: "PEOPLE", count: group.connections.count, color: ContentType.connection.color) {
                            ForEach(group.connections) { connection in
                                rowButton(
                                    icon: "person.fill",
                                    tint: connection.category == .unknown ? ContentType.connection.color : connection.category.color,
                                    title: connection.fullName,
                                    subtitle: connection.displayInfo
                                ) { onSelectConnection(connection) }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
        }
        .background(Theme.Colors.bg1)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.Colors.border).frame(width: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.cyan)
                Text(group.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                countPill(group.connections.count, "people", ContentType.connection.color)
                countPill(group.companies.count, "cos", ContentType.company.color)
                countPill(group.events.count, "events", ContentType.event.color)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func countPill(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.Colors.textDim)
        }
    }

    // MARK: - Section + rows

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(title).hudLabel(tracking: Theme.Tracking.wide, color: color)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            LazyVStack(spacing: 2) { content() }
        }
    }

    private func rowButton(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
