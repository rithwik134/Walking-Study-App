import SwiftUI
import MapKit

/// For setup and checking only — not shown during the actual experiment.
/// Uses Apple's MapKit, not Google Maps, per project requirements.
///
/// One route at a time: drawing both at once made the overlapping Bloomsbury
/// section unreadable. Tapping a waypoint shows both condition scripts, so
/// the wording can be proof-read against the actual street.
struct RouteMapView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRoute: WalkID = .walkA
    @State private var walks: [WalkID: Walk] = [:]
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedWaypointID: String?
    @State private var showingPathGenerator = false

    private var walk: Walk? { walks[selectedRoute] }

    private var tint: Color { selectedRoute == .walkA ? .orange : .purple }

    private var selectedIndex: Int? {
        guard let walk, let selectedWaypointID else { return nil }
        return walk.waypoints.firstIndex { $0.id == selectedWaypointID }
    }

    var body: some View {
        NavigationStack {
            map
                .overlay(alignment: .bottom) {
                    if let walk, let index = selectedIndex {
                        WaypointPreviewCard(
                            waypoint: walk.waypoints[index],
                            index: index,
                            total: walk.waypoints.count,
                            display: .both,
                            onDismiss: { selectedWaypointID = nil }
                        )
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .navigationTitle("Route Overview")
                .navigationBarTitleDisplayMode(.inline)
                .animation(.easeInOut(duration: 0.2), value: selectedWaypointID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showingPathGenerator = true
                            } label: {
                                Label("Generate routed path…", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Developer tools")
                    }
                }
                .safeAreaInset(edge: .top) { routePicker }
                .safeAreaInset(edge: .bottom) { pathStatus }
                .sheet(isPresented: $showingPathGenerator) {
                    if let walk {
                        RoutePathGeneratorView(walk: walk)
                    }
                }
                .onAppear(perform: loadWalks)
                .onChange(of: selectedRoute) {
                    selectedWaypointID = nil
                    cameraPosition = .automatic
                }
        }
    }

    @ViewBuilder
    private var map: some View {
        if let walk {
            Map(position: $cameraPosition, selection: $selectedWaypointID) {
                WaypointMapContent(
                    waypoints: walk.waypoints,
                    selectedID: selectedWaypointID,
                    showRadii: true,
                    routePath: RoutePathStore.shared.polyline(for: walk),
                    pathTint: tint
                )
            }
            .mapStyle(.standard)
        } else {
            ContentUnavailableView(
                "Route not loaded",
                systemImage: "map",
                description: Text("Could not read \(selectedRoute.dataFileName).json from the app bundle.")
            )
        }
    }

    private var routePicker: some View {
        Picker("Route", selection: $selectedRoute) {
            Text("Walk A").tag(WalkID.walkA)
            Text("Walk B").tag(WalkID.walkB)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var pathStatus: some View {
        HStack(spacing: 6) {
            if RoutePathStore.shared.hasRoutedPath(for: selectedRoute) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Routed walking path")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Straight lines — no routed path committed for this walk")
            }
            Spacer()
            Text(selectedRoute.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func loadWalks() {
        for id in WalkID.allCases where walks[id] == nil {
            walks[id] = RouteDataStore.shared.loadWalk(id)
        }
    }
}
