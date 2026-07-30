import SwiftUI
import MapKit

/// For setup and checking only — not shown during the actual experiment.
/// Uses Apple's MapKit, not Google Maps, per project requirements.
struct RouteMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var walkA: Walk?
    @State private var walkB: Walk?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition) {
                if let walkA {
                    MapPolyline(coordinates: walkA.waypoints.map(\.coordinate))
                        .stroke(.orange, lineWidth: 3)
                    ForEach(walkA.waypoints) { waypoint in
                        Marker(waypoint.name, coordinate: waypoint.coordinate)
                            .tint(.orange)
                    }
                }
                if let walkB {
                    MapPolyline(coordinates: walkB.waypoints.map(\.coordinate))
                        .stroke(.purple, lineWidth: 3)
                    ForEach(walkB.waypoints) { waypoint in
                        Marker(waypoint.name, coordinate: waypoint.coordinate)
                            .tint(.purple)
                    }
                }
            }
            .mapStyle(.standard)
            .navigationTitle("Route Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 20) {
                    Label("Walk A", systemImage: "circle.fill").foregroundStyle(.orange)
                    Label("Walk B", systemImage: "circle.fill").foregroundStyle(.purple)
                }
                .font(.footnote)
                .padding(8)
                .background(.thinMaterial)
            }
            .onAppear {
                walkA = RouteDataStore.shared.loadWalk(.walkA)
                walkB = RouteDataStore.shared.loadWalk(.walkB)
            }
        }
    }
}
