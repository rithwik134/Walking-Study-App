import SwiftUI
import MapKit
import CoreLocation

/// The waypoints, their trigger radii and the route line, as one piece of
/// map content shared by the route overview, waypoint test mode and the
/// active walk.
///
/// Written as a `MapContent` type rather than a helper function so all three
/// maps get identical markers, colours and selection behaviour from a single
/// declaration.
struct WaypointMapContent: MapContent {
    let waypoints: [Waypoint]

    /// Waypoints that have already fired — drawn green.
    var triggeredIDs: Set<String> = []
    /// Zero-based index of the waypoint currently armed — drawn orange.
    var activeIndex: Int?
    /// Zero-based index of the waypoint the user tapped — ringed.
    var selectedID: String?

    /// Trigger radii are drawn to true scale. At the radii in the route data
    /// (mostly 5 m) they are sub-pixel unless the map is zoomed well in;
    /// that is deliberate, since seeing their real size relative to the
    /// street is the reason for drawing them at all.
    var showRadii = true

    /// The line to draw. Callers pass `RoutePathStore.shared.polyline(for:)`,
    /// which is the routed walking path when one has been committed and the
    /// straight-line join of the waypoints otherwise.
    var routePath: [CLLocationCoordinate2D] = []
    var pathTint: Color = .blue

    var body: some MapContent {
        if routePath.count >= 2 {
            MapPolyline(coordinates: routePath)
                .stroke(pathTint.opacity(0.8), lineWidth: 4)
        }

        ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
            if showRadii {
                MapCircle(center: waypoint.coordinate, radius: waypoint.triggerRadius)
                    .foregroundStyle(tint(for: waypoint, index: index).opacity(0.18))
                    .stroke(tint(for: waypoint, index: index).opacity(0.7), lineWidth: 1)
            }

            Annotation(waypoint.name, coordinate: waypoint.coordinate) {
                marker(for: waypoint, index: index)
            }
            .tag(waypoint.id)
        }
    }

    private func tint(for waypoint: Waypoint, index: Int) -> Color {
        if triggeredIDs.contains(waypoint.id) { return .green }
        if index == activeIndex { return .orange }
        return .gray
    }

    /// The marker styling carried over from waypoint test mode, plus a
    /// selection ring and a tap target big enough to actually hit on a map.
    private func marker(for waypoint: Waypoint, index: Int) -> some View {
        let isActive = index == activeIndex
        let isSelected = selectedID == waypoint.id
        let colour = tint(for: waypoint, index: index)
        let size: CGFloat = isActive ? 20 : (isSelected ? 18 : 12)

        return Circle()
            .fill(colour)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .overlay(
                Circle()
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(-4)
                    .opacity(isSelected ? 1 : 0)
            )
            .overlay(
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isActive ? 1 : 0)
            )
            // A 12pt dot is not a realistic touch target. Pad the hit area out
            // without changing what is drawn.
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .accessibilityLabel("Waypoint \(index + 1)")
    }
}
