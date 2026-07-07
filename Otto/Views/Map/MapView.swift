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
            OttoDivider()
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
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Text("Map")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.text)

            statPill(icon: "mappin", value: "\(located.count)", label: "cities")
            statPill(icon: "point.3.connected.trianglepath.dotted", value: "\(appState.networkEntries.count)", label: "network")
            statPill(icon: "person.2", value: "\(appState.connections.count)", label: "people")
            statPill(icon: "building.2", value: "\(appState.companies.count)", label: "cos")
            statPill(icon: "calendar", value: "\(appState.events.count)", label: "events")
            statPill(icon: "person.3", value: "\(appState.communities.count)", label: "communities")

            Spacer()

            if unlocated > 0 {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("resolving \(unlocated)…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Button {
                withAnimation { position = .automatic }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                    Text("Fit").font(.system(size: 12))
                }
                .foregroundStyle(Theme.Colors.textDim)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Colors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    private func statPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(Theme.Colors.tertiaryText)
            Text(value).font(Theme.Typography.monoSmall).foregroundStyle(Theme.Colors.text)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.Colors.textDim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
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
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(Theme.Colors.cyan.opacity(isSelected ? 0.95 : (hover ? 0.85 : 0.7)))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .stroke(Theme.Colors.bg0, lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                    Text("\(group.totalCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.bg0)
                }
                if isSelected || hover {
                    Text(group.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Colors.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.Colors.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
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
