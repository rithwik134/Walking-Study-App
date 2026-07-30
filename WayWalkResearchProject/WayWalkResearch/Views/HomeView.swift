import SwiftUI

struct HomeView: View {
    @StateObject private var session = WalkSession()
    @State private var selectedWalkID: WalkID = .walkA
    @State private var selectedLevel: InformationLevel = .navigationOnly
    @State private var testModeEnabled = false
    @State private var showingMap = false
    @State private var showingActiveWalk = false
    @State private var loadError: String?
    @State private var loadedWalk: Walk?

    var body: some View {
        NavigationStack {
            Form {
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
                Button(action: startWalk) {
                    Text("Start Walk")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
            .onAppear { session.requestPermission() }
            .sheet(isPresented: $showingMap) {
                RouteMapView()
            }
            .fullScreenCover(isPresented: $showingActiveWalk) {
                if testModeEnabled, let loadedWalk {
                    WaypointTestView(session: session, walk: loadedWalk) {
                        showingActiveWalk = false
                    }
                } else {
                    ActiveWalkView(session: session) {
                        showingActiveWalk = false
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
        session.start(walk: walk, informationLevel: selectedLevel)
        showingActiveWalk = true
    }
}

#Preview {
    HomeView()
}
