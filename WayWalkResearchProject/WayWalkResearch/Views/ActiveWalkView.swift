import SwiftUI

/// Shown only to the researcher, briefly, before attention goes back to the
/// participant. Deliberately sparse — there is nothing to tap during a walk.
/// A "Debug" toggle reveals a small researcher-only readout panel; hidden by
/// default so the everyday screen is unchanged.
struct ActiveWalkView: View {
    @ObservedObject var session: WalkSession
    var onEnd: () -> Void
    @State private var showDebug = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Button(showDebug ? "Hide Debug" : "Debug") {
                    showDebug.toggle()
                }
                .font(.footnote)
            }

            Spacer()

            Image(systemName: "location.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(session.statusMessage)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let last = session.lastTriggeredWaypointName {
                Text("Last prompt: \(last)")
                    .foregroundStyle(.secondary)
            }

            Text("\(session.triggeredWaypointIDs.count) waypoint(s) triggered so far")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            if showDebug {
                debugPanel
            }

            Button(role: .destructive) {
                session.end()
                onEnd()
            } label: {
                Text("End Walk")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
        .interactiveDismissDisabled()
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
