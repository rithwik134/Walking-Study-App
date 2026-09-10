import SwiftUI
import MapKit
import UIKit

/// Manual mode: the route is shown and tracked exactly as in a normal walk,
/// but nothing is spoken until the researcher presses the cue button.
///
/// The trigger radius is drawn and the button turns green on entering it, so
/// the researcher can see roughly when a prompt is due — but the button stays
/// pressable outside the radius too. That is deliberate: the radius is a hint
/// about timing, not a gate. Judging the right moment is the point of the
/// mode, and a button that refused to work until CoreLocation agreed would
/// take that judgement away at exactly the moment it is wanted.
struct ManualWalkView: View {
    @ObservedObject var session: WalkSession
    let walk: Walk
    var onEnd: () -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedWaypointID: String?
    @State private var isFollowingWalk = true
    @State private var hasEnded = false

    private var currentIndex: Int? {
        let index = session.currentWaypointNumber - 1
        return walk.waypoints.indices.contains(index) ? index : nil
    }

    private var selectedIndex: Int? {
        guard let selectedWaypointID else { return nil }
        return walk.waypoints.firstIndex { $0.id == selectedWaypointID }
    }

    /// From the session rather than inferred locally: `currentWaypointNumber`
    /// stays on the last waypoint once the route ends, so deriving completion
    /// from it left the cue button offering to play waypoint 27 forever.
    private var isComplete: Bool { session.routeIsComplete }

    var body: some View {
        Group {
            if hasEnded {
                WalkSummaryView(session: session, walk: walk, onDone: onEnd)
            } else {
                activeContent
            }
        }
        .interactiveDismissDisabled()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var activeContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                    .walkStatusBanner(session.banner)
                    .overlay(alignment: .bottom) {
                        if let index = selectedIndex {
                            WaypointPreviewCard(
                                waypoint: walk.waypoints[index],
                                index: index,
                                total: walk.waypoints.count,
                                display: .only(session.informationLevel),
                                onDismiss: {
                                    selectedWaypointID = nil
                                    isFollowingWalk = true
                                }
                            )
                            .padding(.bottom, 8)
                        }
                    }

                controlPanel
            }
            .navigationTitle(
                isComplete
                    ? "Walk finished"
                    : "Waypoint \(session.currentWaypointNumber) of \(walk.waypoints.count)"
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedWaypointID)
        .animation(.easeInOut(duration: 0.2), value: session.isInsideCurrentRadius)
        .onAppear { selectFollowedWaypoint() }
        .onChange(of: session.currentWaypointNumber) { selectFollowedWaypoint() }
        // Speech ending is its own sync point: the number does not change when
        // a prompt finishes, so without this the card would sit on the played
        // waypoint until the *next* one fired.
        .onChange(of: session.nowPlayingWaypointID) { selectFollowedWaypoint() }
        .onChange(of: selectedWaypointID) { previous, current in
            if current != nil, current != followedWaypointID, previous != nil {
                isFollowingWalk = false
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedWaypointID) {
            WaypointMapContent(
                waypoints: walk.waypoints,
                triggeredIDs: session.triggeredWaypointIDs,
                activeIndex: session.currentWaypointNumber - 1,
                selectedID: selectedWaypointID,
                showRadii: true,
                routePath: RoutePathStore.shared.polyline(for: walk),
                pathTint: .indigo
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
        .onAppear {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: walk.waypoints.first?.coordinate
                        ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                )
            )
        }
    }

    /// While a prompt is speaking, the card holds on the waypoint being heard:
    /// `currentWaypointNumber` has already moved to the next armed waypoint by
    /// then, so following it alone showed one script while playing another.
    private var followedWaypointID: String? {
        if let playing = session.nowPlayingWaypointID,
           walk.waypoints.contains(where: { $0.id == playing }) {
            return playing
        }
        guard let index = currentIndex else { return nil }
        return walk.waypoints[index].id
    }

    private func selectFollowedWaypoint() {
        guard isFollowingWalk, let id = followedWaypointID else { return }
        selectedWaypointID = id
    }

    // MARK: - Controls

    private var controlPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Manual · \(session.informationLevel.shortName)", systemImage: "hand.tap.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.indigo)
                Spacer()
                // Route length for this condition, not the raw waypoint count:
                // waypoints off this condition's route are skipped, so the cue
                // button never offers them.
                Text("\(session.triggeredWaypointIDs.count) of \(walk.routeLength(for: session.informationLevel)) played")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = session.loggingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = session.locationError {
                Label(error, systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cueButton
            cueHint

            Button(role: .destructive) {
                session.end()
                hasEnded = true
            } label: {
                Text("End Walk")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.thinMaterial)
    }

    private var cueButton: some View {
        Button {
            session.playCurrentWaypoint()
        } label: {
            Label(
                isComplete ? "Walk finished" : "Play waypoint \(session.currentWaypointNumber)",
                systemImage: isComplete ? "checkmark.circle.fill" : "speaker.wave.2.fill"
            )
            .font(.title3.bold())
            .frame(maxWidth: .infinity)
            .frame(height: 64)
        }
        .buttonStyle(.borderedProminent)
        // Green once inside the radius, grey outside — but still pressable
        // either way, which is the whole point of the mode. `.disabled` is
        // used only when there is genuinely nothing left to play.
        //
        // "Inside" now means a location fix put the participant within the
        // waypoint's `triggerRadius`, not that CoreLocation reported region
        // entry. It therefore lights much later than it used to — at ~10m
        // rather than the 25-33m the coarse region reported — and can flicker
        // at the boundary. That is the honest reading, and it finally matches
        // the circle the map draws to scale. The distance in `cueHint` below
        // is the better cue for anticipating a prompt.
        .tint(session.isInsideCurrentRadius ? .green : .gray)
        .disabled(isComplete)
    }

    @ViewBuilder
    private var cueHint: some View {
        if isComplete {
            Text("Every waypoint has been played.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if session.isInsideCurrentRadius {
            Label("Inside the trigger radius — this is roughly when the prompt is due.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Text(
                session.distanceToNext.map { String(format: "%.0f m away — playable at any time.", $0) }
                    ?? "Waiting for a location fix — playable at any time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
