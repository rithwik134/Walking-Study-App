import SwiftUI

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

    private var trimmedParticipantID: String {
        participantID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool { !trimmedParticipantID.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. P03", text: $participantID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Participant")
                } footer: {
                    // Deliberately blank on every launch rather than
                    // remembered: an ID auto-filled from the previous
                    // participant is a silent mislabelling of study data,
                    // which is far worse than retyping four characters.
                    Text("Written into the session file name and every row of the log. Required.")
                }

                Section("Select Walk") {
                    Picker("Walk", selection: $selectedWalkID) {
                        ForEach(WalkID.allCases) { id in
                            Text(id.displayName).tag(id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Select Information Level") {
                    Picker("Information level", selection: $selectedLevel) {
                        ForEach(InformationLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Button {
                        showingMap = true
                    } label: {
                        Label("View route map", systemImage: "map")
                    }

                    NavigationLink {
                        SessionsView()
                    } label: {
                        Label("Past sessions", systemImage: "tray.full")
                    }
                }

                Section("Testing") {
                    Toggle("Waypoint Test Mode", isOn: $testModeEnabled)
                }

                if let loadError {
                    Section {
                        Text(loadError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("WayWalk Research")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button(action: startWalk) {
                        Text("Start Walk")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)

                    if !canStart {
                        Text("Enter a participant ID to start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.bar)
            }
            .onAppear { session.requestPermission() }
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

    private func startWalk() {
        guard let walk = RouteDataStore.shared.loadWalk(selectedWalkID) else {
            loadError = "Could not load \(selectedWalkID.dataFileName).json — check it's added to the app target."
            return
        }
        loadError = nil
        loadedWalk = walk
        session.start(
            walk: walk,
            informationLevel: selectedLevel,
            participantID: trimmedParticipantID
        )
        showingActiveWalk = true
    }
}

#Preview {
    HomeView()
}
