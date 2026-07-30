import SwiftUI
import MapKit

/// Opt-in researcher tool for fine-tuning waypoint positions and radii before
/// real data collection. Shows every waypoint on the map at once, the
/// participant's live position, which waypoint is currently armed, and which
/// have already fired. Entirely separate from ActiveWalkView — the normal
/// experiment flow is unaffected by this screen's existence.
struct WaypointTestView: View {
    @ObservedObject var session: WalkSession
    let walk: Walk
    var onEnd: () -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $cameraPosition) {
                    ForEach(Array(walk.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        Annotation(waypoint.name, coordinate: waypoint.coordinate) {
                            waypointMarker(for: waypoint, index: index)
                        }
                    }
                    if let lat = session.currentLatitude, let lng = session.currentLongitude {
                        Annotation("You", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.standard)
                .frame(maxHeight: .infinity)

                statusStrip
            }
            .navigationTitle("Waypoint Test Mode")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: walk.waypoints.first?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waypoint \(session.currentWaypointNumber) of \(walk.waypoints.count)")
                    .font(.headline)
                Spacer()
                Text(badgeText)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.2))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }

            Text("Distance to next: \(session.distanceToNext.map { String(format: "%.0fm", $0) } ?? "—")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let last = session.lastTriggeredWaypointName {
                Label("Triggered: \(last)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            Button(role: .destructive) {
                session.end()
                onEnd()
            } label: {
                Text("End Test")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding()
        .background(.thinMaterial)
    }

    private var badgeText: String {
        if session.isConfirmingArrival { return "CONFIRMING" }
        if session.isNextWaypointArmed { return "ARMED" }
        return "—"
    }

    private var badgeColor: Color {
        if session.isConfirmingArrival { return .orange }
        if session.isNextWaypointArmed { return .green }
        return .gray
    }

    @ViewBuilder
    private func waypointMarker(for waypoint: Waypoint, index: Int) -> some View {
        let isTriggered = session.triggeredWaypointIDs.contains(waypoint.id)
        let isActive = index == session.currentWaypointNumber - 1

        Circle()
            .fill(isTriggered ? Color.green : (isActive ? Color.orange : Color.gray))
            .frame(width: isActive ? 20 : 12, height: isActive ? 20 : 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .overlay(
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isActive ? 1 : 0)
            )
    }
}
