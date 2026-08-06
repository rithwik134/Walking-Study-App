import SwiftUI
import MapKit

/// Opt-in researcher tool for fine-tuning waypoint positions and radii before
/// real data collection. Shows every waypoint on the map at once with its
/// trigger radius drawn to scale, the participant's live position, which
/// waypoint is currently armed, and which have already fired. Tapping a
/// waypoint reveals both condition scripts, so the wording can be checked in
/// place. Entirely separate from ActiveWalkView — the normal experiment flow
/// is unaffected by this screen's existence.
struct WaypointTestView: View {
    @ObservedObject var session: WalkSession
    let walk: Walk
    var onEnd: () -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedWaypointID: String?
    /// Set when the selection came from the walk advancing rather than from a
    /// tap, so auto-following does not fight a researcher inspecting a
    /// different waypoint.
    @State private var isFollowingWalk = true

    private var selectedIndex: Int? {
        guard let selectedWaypointID else { return nil }
        return walk.waypoints.firstIndex { $0.id == selectedWaypointID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                    .overlay(alignment: .bottom) {
                        if let index = selectedIndex {
                            WaypointPreviewCard(
                                waypoint: walk.waypoints[index],
                                index: index,
                                total: walk.waypoints.count,
                                display: .both,
                                onDismiss: {
                                    selectedWaypointID = nil
                                    isFollowingWalk = true
                                }
                            )
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                statusStrip
            }
            .navigationTitle("Waypoint Test Mode")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.easeInOut(duration: 0.2), value: selectedWaypointID)
            .onAppear {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: walk.waypoints.first?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
                selectFollowedWaypoint()
            }
            .onChange(of: session.currentWaypointNumber) {
                selectFollowedWaypoint()
            }
            .onChange(of: selectedWaypointID) { previous, current in
                // A tap on a different waypoint means the researcher is
                // inspecting, so stop dragging the card along with the walk
                // until they dismiss it.
                if current != nil, current != followedWaypointID, previous != nil {
                    isFollowingWalk = false
                }
            }
        }
    }

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedWaypointID) {
            WaypointMapContent(
                waypoints: walk.waypoints,
                triggeredIDs: session.triggeredWaypointIDs,
                activeIndex: session.currentWaypointNumber - 1,
                selectedID: selectedWaypointID,
                showRadii: true,
                routePath: RoutePathStore.shared.polyline(for: walk),
                pathTint: .blue
            )

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
    }

    /// The waypoint the walk is currently waiting on.
    private var followedWaypointID: String? {
        let index = session.currentWaypointNumber - 1
        guard walk.waypoints.indices.contains(index) else { return nil }
        return walk.waypoints[index].id
    }

    private func selectFollowedWaypoint() {
        guard isFollowingWalk, let id = followedWaypointID else { return }
        selectedWaypointID = id
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

            if !RoutePathStore.shared.hasRoutedPath(for: walk.id) {
                Label(
                    "No routed path committed — showing straight lines between waypoints.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

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
}
