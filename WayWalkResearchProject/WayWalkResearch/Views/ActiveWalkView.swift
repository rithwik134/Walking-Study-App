import SwiftUI
import MapKit
import UIKit

/// The researcher's screen during a real walk.
///
/// It shows the route as it is actually walked — waypoints, trigger radii and
/// the routed pavement path — plus the exact script that will be spoken at
/// the waypoint currently armed, in whichever condition this session is
/// running. The one thing there is to *do* here is raise a flag: a timestamp
/// marking a moment worth returning to when the physiological data is
/// analysed later.
struct ActiveWalkView: View {
    @ObservedObject var session: WalkSession
    let walk: Walk
    var onEnd: () -> Void

    @State private var showDebug = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedWaypointID: String?
    @State private var isFollowingWalk = true
    @State private var noteTarget: FlagNoteTarget?
    @State private var hasEnded = false

    /// Wraps a flag's event id so it can drive a `.sheet(item:)`.
    private struct FlagNoteTarget: Identifiable {
        let id: UUID
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var selectedIndex: Int? {
        guard let selectedWaypointID else { return nil }
        return walk.waypoints.firstIndex { $0.id == selectedWaypointID }
    }

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
                session.routeIsComplete
                    ? "Walk finished"
                    : "Waypoint \(session.currentWaypointNumber) of \(walk.waypoints.count)"
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedWaypointID)
        .onAppear { selectFollowedWaypoint() }
        .onChange(of: session.currentWaypointNumber) { selectFollowedWaypoint() }
        .onChange(of: selectedWaypointID) { previous, current in
            if current != nil, current != followedWaypointID, previous != nil {
                isFollowingWalk = false
            }
        }
        .sheet(item: $noteTarget) { target in
            FlagNoteSheet(
                onSave: { note in session.attachNote(note, to: target.id) }
            )
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

    private var followedWaypointID: String? {
        let index = session.currentWaypointNumber - 1
        guard walk.waypoints.indices.contains(index) else { return nil }
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
                Label(session.informationLevel.rawValue, systemImage: "speaker.wave.2.fill")
                    .font(.caption.bold())
                    .foregroundStyle(session.informationLevel == .navigationOnly ? .blue : .purple)
                Spacer()
                Button(showDebug ? "Hide Debug" : "Debug") { showDebug.toggle() }
                    .font(.footnote)
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

            manualTriggerControls
            flagControls

            if showDebug { debugPanel }

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

    /// Failsafe for a geofence that does not fire.
    ///
    /// Without it a missed trigger is unrecoverable: the next waypoint is only
    /// armed once the current one fires, so the walk stops dead and the rest
    /// of the route produces nothing — with a participant standing there.
    /// Forcing the prompt delivers the instruction they were owed and unblocks
    /// the sequence.
    private var manualTriggerControls: some View {
        VStack(spacing: 4) {
            Button {
                session.playCurrentWaypoint()
            } label: {
                Label(
                    session.routeIsComplete
                        ? "Walk finished"
                        : "Play waypoint \(session.currentWaypointNumber)",
                    systemImage: session.routeIsComplete
                        ? "checkmark.circle.fill" : "speaker.wave.2.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(session.routeIsComplete)
        }
    }

    private var flagControls: some View {
        VStack(spacing: 8) {
            // The timestamp is recorded the instant this is tapped. The note
            // sheet opens afterwards and is entirely optional — cancelling it
            // still leaves a valid flag.
            Button {
                if let id = session.addFlag() {
                    noteTarget = FlagNoteTarget(id: id)
                }
            } label: {
                Label("Flag this moment", systemImage: "flag.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            HStack {
                if let last = session.lastFlagTime {
                    Text("Last flag: \(Self.clockFormatter.string(from: last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No flags yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.canUndoLastFlag {
                    Button("Undo last flag") { session.undoLastFlag() }
                        .font(.caption)
                }
            }
        }
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            debugRow("GPS accuracy", session.currentAccuracy.map { String(format: "±%.0fm", $0) } ?? "—")
            debugRow("Waypoint", "\(session.currentWaypointNumber)")
            debugRow("Distance to next", session.distanceToNext.map { String(format: "%.0fm", $0) } ?? "—")
            debugRow("Latitude", session.currentLatitude.map { String(format: "%.6f", $0) } ?? "—")
            debugRow("Longitude", session.currentLongitude.map { String(format: "%.6f", $0) } ?? "—")
            debugRow("Next waypoint armed", session.isNextWaypointArmed ? "Yes" : "No")
            debugRow("Confirming arrival", session.isConfirmingArrival ? "Yes" : "No")
            debugRow("Triggered", "\(session.triggeredWaypointIDs.count) of \(walk.waypoints.count)")
            debugRow("Voice", session.audioVoiceDescription)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

/// Optional free text for a flag that has *already* been recorded. Dismissing
/// this without typing anything is a supported outcome, not a cancellation —
/// the flag and its timestamp are on disk before this ever appears.
private struct FlagNoteSheet: View {
    var onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isFocused)
                } footer: {
                    Text("The flag has already been saved with its timestamp. A note is optional — skip it if now is not the moment.")
                }
            }
            .navigationTitle("Add a note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(note)
                        dismiss()
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }
}

/// Shown once a walk has ended: what was recorded, and the file it went into.
/// Shared with `ManualWalkView` — both end the same way.
struct WalkSummaryView: View {
    @ObservedObject var session: WalkSession
    let walk: Walk
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Recorded") {
                    LabeledContent("Route", value: walk.displayName)
                    LabeledContent("Condition", value: session.informationLevel.rawValue)
                    LabeledContent(
                        "Waypoints triggered",
                        value: "\(session.triggeredWaypointIDs.count) of \(walk.waypoints.count)"
                    )
                    LabeledContent("Flags", value: "\(flagCount)")
                }

                if session.triggeredWaypointIDs.count < walk.waypoints.count {
                    Section {
                        Label(
                            "Not every waypoint fired.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                Section {
                    if let url = session.lastSessionFileURL {
                        ShareLink(item: url) {
                            Label("Export \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        Text("Also saved on the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No session file was written.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Session data")
                }

                if let error = session.loggingError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Walk Complete")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
        }
    }

    private var flagCount: Int {
        session.logger?.events.filter { $0.type == .flag }.count ?? 0
    }
}
