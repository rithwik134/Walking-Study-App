import SwiftUI

/// Setup screen: who is walking, which route, which condition.
///
/// Laid out to fit without scrolling. The route and condition names are long
/// enough that inline pickers wrapped them onto two lines each and pushed the
/// Start button off the screen, so both are segmented controls with the full
/// name shown underneath as a caption.
struct HomeView: View {
    @StateObject private var session = WalkSession()
    @State private var participantID = ""
    @State private var selectedWalkID: WalkID = .walkA
    @State private var selectedLevel: InformationLevel = .navigationOnly
    @State private var testModeEnabled = false
    @State private var showingMap = false
    @State private var showingActiveWalk = false
    @State private var loadError: String?
    @State private var loadedWalk: Walk?
    /// Both routes, loaded up front so the waypoint count can be shown and a
    /// broken route file surfaces now rather than when Start is pressed with a
    /// participant already standing there.
    @State private var walks: [WalkID: Walk] = [:]

    private var trimmedParticipantID: String {
        participantID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool { !trimmedParticipantID.isEmpty }

    private var mode: SessionMode { testModeEnabled ? .test : .study }

    private var selectedWalk: Walk? { walks[selectedWalkID] }

    var body: some View {
        NavigationStack {
            Form {
                participantSection
                routeSection
                conditionSection

                testingSection

                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("WayWalk Research")
            // Inline rather than large: a large title costs roughly a third of
            // the screen here, which pushed the test-mode toggle below the
            // fold and reintroduced the scrolling this layout exists to avoid.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Secondary navigation — both are used either side of a walk,
                // never during setup, so they do not belong in the flow.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingMap = true
                    } label: {
                        Image(systemName: "map")
                    }
                    .accessibilityLabel("View route map")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SessionsView()
                    } label: {
                        Image(systemName: "tray.full")
                    }
                    .accessibilityLabel("Past sessions")
                }
            }
            .safeAreaInset(edge: .bottom) { startBar }
            .onAppear {
                session.requestPermission()
                loadWalks()
            }
            .sheet(isPresented: $showingMap) {
                RouteMapView()
            }
            .fullScreenCover(isPresented: $showingActiveWalk) {
                if let loadedWalk {
                    if testModeEnabled {
                        WaypointTestView(session: session, walk: loadedWalk) {
                            showingActiveWalk = false
                        }
                    } else {
                        ActiveWalkView(session: session, walk: loadedWalk) {
                            showingActiveWalk = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var participantSection: some View {
        Section {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                TextField("e.g. P03", text: $participantID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
        } header: {
            Text("Participant")
        } footer: {
            // Deliberately blank on every launch rather than remembered: an ID
            // auto-filled from the previous participant is a silent
            // mislabelling of study data, which is far worse than retyping
            // four characters.
            Text("Required. Written into the file name and every log row.")
        }
    }

    private var routeSection: some View {
        Section("Route") {
            Picker("Route", selection: $selectedWalkID) {
                Text("Walk A").tag(WalkID.walkA)
                Text("Walk B").tag(WalkID.walkB)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                Text(routeDescription)
                    .font(.footnote)
                if let count = selectedWalk?.waypoints.count {
                    Text("\(count) waypoints")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The display name without the "Walk A — " prefix the segmented control
    /// already shows.
    private var routeDescription: String {
        let name = selectedWalkID.displayName
        guard let separator = name.range(of: " — ") else { return name }
        return String(name[separator.upperBound...])
    }

    private var conditionSection: some View {
        Section("Condition") {
            Picker("Condition", selection: $selectedLevel) {
                ForEach(InformationLevel.allCases) { level in
                    Text(level.shortName).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedLevel.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var testingSection: some View {
        Section {
            Toggle("Waypoint Test Mode", isOn: $testModeEnabled.animation())
        } header: {
            Text("Testing")
        } footer: {
            if testModeEnabled {
                Label(
                    "This run is still recorded, but the file is named TEST and every row is marked session_mode = test, so it cannot be mistaken for a participant's data.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text("Shows a live map of every waypoint instead of the walk screen, for checking positions and radii.")
            }
        }
    }

    // MARK: - Start

    private var startBar: some View {
        VStack(spacing: 8) {
            summaryLine

            Button(action: startWalk) {
                Text(testModeEnabled ? "Start Test Mode" : "Start Walk")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(testModeEnabled ? .orange : .accentColor)
            .disabled(!canStart)
        }
        .padding()
        .background(.bar)
    }

    /// What is about to be recorded, so it can be checked at a glance before
    /// committing. Keeps a fixed height whether or not the hint is showing, so
    /// enabling the toggle does not shift the button under a thumb.
    private var summaryLine: some View {
        Group {
            if canStart {
                HStack(spacing: 6) {
                    if testModeEnabled {
                        Text("TEST")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    Text(trimmedParticipantID)
                        .fontWeight(.semibold)
                    Text("·")
                    Text(selectedWalkID == .walkA ? "Walk A" : "Walk B")
                    Text("·")
                    Text(selectedLevel.shortName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Enter a participant ID to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 16)
    }

    // MARK: - Actions

    private func loadWalks() {
        for id in WalkID.allCases where walks[id] == nil {
            walks[id] = RouteDataStore.shared.loadWalk(id)
        }
        let missing = WalkID.allCases.filter { walks[$0] == nil }
        loadError = missing.isEmpty
            ? nil
            : "Could not load \(missing.map { "\($0.dataFileName).json" }.joined(separator: ", ")) — check they're added to the app target."
    }

    private func startWalk() {
        guard let walk = selectedWalk ?? RouteDataStore.shared.loadWalk(selectedWalkID) else {
            loadError = "Could not load \(selectedWalkID.dataFileName).json — check it's added to the app target."
            return
        }
        loadError = nil
        loadedWalk = walk
        session.start(
            walk: walk,
            informationLevel: selectedLevel,
            participantID: trimmedParticipantID,
            mode: mode
        )
        showingActiveWalk = true
    }
}

#Preview {
    HomeView()
}
