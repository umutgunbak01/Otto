import SwiftUI
import MapKit

/// Location map: one pin per city that appears anywhere in your data
/// (connections + companies + events). Selecting a pin opens a side panel
/// listing the people, companies and events there.
struct MapView: View {
    @Environment(AppState.self) private var appState

    @State private var position: MapCameraPosition = .automatic
    @State private var selectedKey: String?

    // Drill-down sheets
    @State private var connectionTarget: ConnTarget?
    @State private var companyTarget: CompanyTarget?
    @State private var eventTarget: EventTarget?

    var body: some View {
        // Build the city index once per render, then derive everything from it
        // — avoids re-normalizing thousands of locations multiple times while
        // pins stream in during geocoding.
        let groups = CityIndex.build(
            connections: appState.connections,
            companies: appState.companies,
            events: appState.events,
            coordinates: appState.cityCoordinates
        )
        let located = groups.filter { $0.hasCoordinate }
        let unlocated = groups.count - located.count
        let selected = selectedKey.flatMap { key in groups.first { $0.id == key } }

        return VStack(spacing: 0) {
            header(located: located, unlocated: unlocated)
            OttoDivider()
            HStack(spacing: 0) {
                mapArea(located: located, totalGroups: groups.count)
                if let group = selected {
                    CityDetailPanel(
                        group: group,
                        onClose: { withAnimation(.easeInOut(duration: 0.2)) { selectedKey = nil } },
                        onSelectConnection: { connectionTarget = ConnTarget(id: $0.id, connection: $0) },
                        onSelectCompany: { companyTarget = CompanyTarget(id: $0.id, company: $0) },
                        onSelectEvent: { eventTarget = EventTarget(id: $0.id, event: $0) }
                    )
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onAppear { appState.refreshCityCoordinates() }
        .sheet(item: $connectionTarget) { target in
            ConnectionDetailView(connection: target.connection, onClose: { connectionTarget = nil })
                .environment(appState)
                .frame(minWidth: 560, minHeight: 640)
        }
        .sheet(item: $companyTarget) { target in
            CompanyEditorSheet(company: target.company).environment(appState)
        }
        .sheet(item: $eventTarget) { target in
            EventEditorSheet(event: target.event).environment(appState)
        }
    }

    // MARK: - Map

    private func mapArea(located: [CityGroup], totalGroups: Int) -> some View {
        ZStack {
            Map(position: $position) {
                ForEach(located) { group in
                    if let coord = group.coordinate?.coordinate {
                        Annotation("", coordinate: coord, anchor: .bottom) {
                            CityPin(group: group, isSelected: selectedKey == group.id) {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedKey = group.id }
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
            }

            if located.isEmpty {
                emptyOverlay(totalGroups: totalGroups)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyOverlay(totalGroups: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
            if totalGroups == 0 {
                Text("No locations yet")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Add a city to a company or event, or import connections with locations.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            } else {
                ProgressView().scaleEffect(0.7)
                Text("Resolving \(totalGroups) cities…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(24)
        .background(Theme.Colors.bg1.opacity(0.85))
        .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
    }

    // MARK: - Header

    private func header(located: [CityGroup], unlocated: Int) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Text("⊕ MAP")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Colors.cyan)
                .shadow(color: Theme.Colors.cyanGlow, radius: 4)

            statPill(icon: "mappin", value: "\(located.count)", label: "cities")
            statPill(icon: "person.2", value: "\(appState.connections.count)", label: "people")
            statPill(icon: "building.2", value: "\(appState.companies.count)", label: "cos")
            statPill(icon: "calendar", value: "\(appState.events.count)", label: "events")

            Spacer()

            if unlocated > 0 {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("resolving \(unlocated)…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Button {
                withAnimation { position = .automatic }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                    Text("Fit").font(.system(size: 11))
                }
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.Colors.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Theme.Colors.cyanDim)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.Colors.text)
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.Colors.textDim)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
    }

    // MARK: - Sheet target wrappers

    private struct ConnTarget: Identifiable { let id: UUID; let connection: Connection }
    private struct CompanyTarget: Identifiable { let id: UUID; let company: Company }
    private struct EventTarget: Identifiable { let id: UUID; let event: Event }
}

// MARK: - City Pin

private struct CityPin: View {
    let group: CityGroup
    let isSelected: Bool
    let action: () -> Void
    @State private var hover = false

    private var diameter: CGFloat {
        min(46, 20 + CGFloat(group.totalCount) * 0.7)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.cyan.opacity(isSelected ? 0.95 : (hover ? 0.85 : 0.7)))
                        .frame(width: diameter, height: diameter)
                        .shadow(color: Theme.Colors.cyanGlow, radius: isSelected || hover ? 10 : 5)
                    Circle()
                        .stroke(Theme.Colors.bg0, lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                    Text("\(group.totalCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.bg0)
                }
                if isSelected || hover {
                    Text(group.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.text)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.Colors.bg0.opacity(0.85))
                        .overlay(Rectangle().stroke(Theme.Colors.cyan.opacity(0.5), lineWidth: 1))
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
