import SwiftUI
import MapKit

/// Location map: one pin per city that appears anywhere in your data
/// (network-hub entries + connections + companies + events). Selecting a pin
/// opens a side panel listing everything you know there.
struct MapView: View {
    @Environment(AppState.self) private var appState

    @State private var position: MapCameraPosition = .automatic
    @State private var selectedKey: String?

    var body: some View {
        // Build the city index once per render, then derive everything from it
        // — avoids re-normalizing thousands of locations multiple times while
        // pins stream in during geocoding.
        let groups = CityIndex.build(
            connections: appState.connections,
            companies: appState.companies,
            events: appState.events,
            networkEntries: appState.networkEntries,
            communities: appState.communities,
            coordinates: appState.cityCoordinates
        )
        let located = groups.filter { $0.hasCoordinate }
        let unlocated = groups.count - located.count
        let selected = selectedKey.flatMap { key in groups.first { $0.id == key } }

        return VStack(spacing: 0) {
            header(located: located, unlocated: unlocated)
            if let group = selected {
                // Selected city → full-width tabbed, inline-editable table.
                CityTableView(group: group, onBack: {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedKey = nil }
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mapArea(located: located, totalGroups: groups.count)
            }
        }
        .onAppear { appState.refreshCityCoordinates() }
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
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls {
                MapZoomStepper()
                MapCompass()
            }

            if located.isEmpty {
                emptyOverlay(totalGroups: totalGroups)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) { mapLegend }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bottom-leading totals legend on the map panel (mockup .maplegend).
    private var mapLegend: some View {
        Text("\(appState.connections.count) people · \(appState.companies.count) companies · \(appState.events.count) events".uppercased())
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(Theme.Tracking.xxwide)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.Colors.bgPage.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .padding(12)
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
                Text("Add a location to a Network Hub entry, company, or event — or import connections with locations.")
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
        .background(Theme.Colors.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Colors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Header

    private func header(located: [CityGroup], unlocated: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Map")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: "\(appState.connections.count) people · \(located.count) cities")

            statCapsule("\(appState.networkEntries.count) network")
            statCapsule("\(appState.companies.count) cos")
            statCapsule("\(appState.events.count) events")
            statCapsule("\(appState.communities.count) communities")

            Spacer(minLength: 8)

            if unlocated > 0 {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("resolving \(unlocated)…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            OttoBarButton(label: "Fit", systemImage: "arrow.up.left.and.arrow.down.right") {
                withAnimation { position = .automatic }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// Compact mono capsule for the secondary totals.
    private func statCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(Theme.Colors.panel))
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }

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
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.cyan.opacity(isSelected ? 0.95 : (hover ? 0.85 : 0.7)))
                        .frame(width: diameter, height: diameter)
                        .shadow(color: Theme.Colors.cyan.opacity(0.5), radius: 8)
                    Circle()
                        .stroke(Theme.Colors.bg0, lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                    Text("\(group.totalCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.bg0)
                }
                if isSelected || hover {
                    HStack(spacing: 4) {
                        Text(group.displayName)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.Colors.text)
                        Text("\(group.totalCount)")
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.Colors.bgPage.opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
