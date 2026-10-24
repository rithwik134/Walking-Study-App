import SwiftUI
import CoreLocation
import UIKit

struct ParticipantWalkChoice: Identifiable, Hashable {
    let walkID: WalkID
    let level: InformationLevel

    var id: String { "\(walkID.rawValue)-\(level.rawValue)" }
    var title: String { "\(walkID == .walkA ? "Walk A" : "Walk B") — \(conditionName)" }
    var conditionName: String {
        level == .navigationOnly ? "Navigation only" : "Navigation plus context"
    }
    var startingPlace: String { walkID == .walkA ? "UCL Main Entrance" : "Central House" }
    var destination: String { walkID == .walkA ? "Central House" : "UCL Main Entrance" }
    var routeDescription: String { "From \(startingPlace) to \(destination)" }

    static let all: [Self] = WalkID.allCases.flatMap { walk in
        InformationLevel.allCases.map { Self(walkID: walk, level: $0) }
    }
}

/// Holds confirmation intent separately from the running session. Only the
/// sheet's dismissal callback can consume a confirmed request and create a CSV.
@MainActor
final class ParticipantSetup: ObservableObject {
    struct Launch: Identifiable {
        let id = UUID()
        let walk: Walk
        let choice: ParticipantWalkChoice
    }

    @Published var participantID = ""
    @Published var confirmation: ParticipantWalkChoice?
    @Published var activeLaunch: Launch?
    @Published private(set) var error: String?
    let walks: [WalkID: Walk]
    private var pendingStart: ParticipantWalkChoice?

    init(loadWalk: (WalkID) -> Walk? = { RouteDataStore.shared.loadWalk($0) }) {
        walks = Dictionary(uniqueKeysWithValues: WalkID.allCases.compactMap { id in
            loadWalk(id).map { (id, $0) }
        })
    }

    var trimmedID: String { participantID.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func permissionMessage(_ status: CLAuthorizationStatus) -> String? {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return nil
        case .notDetermined: return "Allow location access to start a walk. Respond to the iPhone permission request."
        case .denied: return "Location access is off. Open Settings and allow location access to start a walk."
        case .restricted: return "Location access is restricted on this iPhone. A walk cannot start until the restriction is removed."
        @unknown default: return "Location access is unavailable. Check this app’s location settings."
        }
    }

    func unavailableMessage(for choice: ParticipantWalkChoice) -> String? {
        guard let walk = walks[choice.walkID], walk.routeLength(for: choice.level) > 0 else {
            return "\(choice.title) is unavailable because its route could not be loaded."
        }
        return nil
    }

    func startProblem(for choice: ParticipantWalkChoice, authorization: CLAuthorizationStatus) -> String? {
        if trimmedID.isEmpty { return "Enter a participant ID before starting. Cancel to return to the ID field." }
        return unavailableMessage(for: choice) ?? Self.permissionMessage(authorization)
    }

    func select(_ choice: ParticipantWalkChoice) {
        guard activeLaunch == nil, pendingStart == nil else { return }
        error = unavailableMessage(for: choice)
        if error == nil { confirmation = choice }
    }

    func confirm(authorization: CLAuthorizationStatus) {
        guard let choice = confirmation, pendingStart == nil, activeLaunch == nil else { return }
        error = startProblem(for: choice, authorization: authorization)
        guard error == nil else { return }
        pendingStart = choice
        confirmation = nil
    }

    func cancel() {
        pendingStart = nil
        confirmation = nil
        error = nil
    }

    @discardableResult
    func confirmationDismissed(session: WalkSession) -> Bool {
        guard let choice = pendingStart else { return false }
        pendingStart = nil
        guard activeLaunch == nil, !session.isActive else { return false }
        // Permission may change while the dismissal animation is running.
        error = startProblem(for: choice, authorization: session.authorizationStatus)
        guard error == nil, let walk = walks[choice.walkID] else { return false }
        session.start(walk: walk, informationLevel: choice.level, participantID: trimmedID,
                      mode: .study, requiresManualFirstTrigger: false)
        activeLaunch = Launch(walk: walk, choice: choice)
        return true
    }
}

struct ParticipantHomeView: View {
    @StateObject private var session = WalkSession(audioPlayer: RecordedAudioPromptPlayer())
    @StateObject private var setup = ParticipantSetup()
    @Environment(\.openURL) private var openURL
    @FocusState private var editingID: Bool
    @AccessibilityFocusState private var accessibilityFocus: Focus?
    @State private var lastChoice: ParticipantWalkChoice?

    private enum Focus: Hashable {
        case participantID, error, walk(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                participantField
                Text("Navigation only gives directions. Navigation plus context also describes your surroundings.")
                permissionStatus

                if let error = setup.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityFocused($accessibilityFocus, equals: .error)
                }

                ForEach(ParticipantWalkChoice.all) { choice in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            editingID = false
                            lastChoice = choice
                            setup.select(choice)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(choice.title).font(.headline)
                                Text(choice.routeDescription).font(.body)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                            .padding(.vertical, 8)
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens details to review before starting")
                        .accessibilityIdentifier("walk.\(choice.walkID.rawValue).\(choice.level == .navigationOnly ? "navigation" : "context")")
                        .accessibilityFocused($accessibilityFocus, equals: .walk(choice.id))
                        .disabled(setup.unavailableMessage(for: choice) != nil)

                        if let message = setup.unavailableMessage(for: choice) {
                            Text(message).foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Choose your walk")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    editingID = false
                    accessibilityFocus = .participantID
                }
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .onAppear { session.requestPermission() }
        .onDisappear {
            // A full-screen walk also hides this view; retain its participant.
            // Popping this destination back to role selection clears the ID.
            if setup.activeLaunch == nil && setup.confirmation == nil {
                setup.participantID = ""
            }
        }
        .onChange(of: setup.error) { _, error in
            if error != nil && setup.confirmation == nil { accessibilityFocus = .error }
        }
        .sheet(item: $setup.confirmation, onDismiss: confirmationDismissed) { choice in
            ParticipantConfirmationView(setup: setup, session: session, choice: choice)
        }
        .fullScreenCover(item: $setup.activeLaunch, onDismiss: restoreChoiceFocus) { launch in
            ActiveWalkView(session: session, walk: launch.walk, isParticipantSession: true) {
                setup.activeLaunch = nil
            }
        }
    }

    private var participantField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Participant ID").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Enter the ID provided by your researcher, for example P03.")
            TextField("Participant ID", text: $setup.participantID)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .frame(minHeight: 44)
                .submitLabel(.done)
                .focused($editingID)
                .accessibilityFocused($accessibilityFocus, equals: .participantID)
                .accessibilityIdentifier("participant.id")
                .onSubmit { editingID = false }
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if let message = ParticipantSetup.permissionMessage(session.authorizationStatus) {
            Text(message)
            if session.authorizationStatus == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            }
        } else if session.authorizationStatus == .authorizedWhenInUse {
            Text("For walks with the screen locked, set Location access to Always in Settings.")
        }
    }

    private func confirmationDismissed() {
        if !setup.confirmationDismissed(session: session) { restoreChoiceFocus() }
    }

    private func restoreChoiceFocus() {
        if setup.error != nil { accessibilityFocus = .error }
        else if setup.trimmedID.isEmpty { accessibilityFocus = .participantID }
        else if let lastChoice { accessibilityFocus = .walk(lastChoice.id) }
    }
}

private struct ParticipantConfirmationView: View {
    @ObservedObject var setup: ParticipantSetup
    @ObservedObject var session: WalkSession
    let choice: ParticipantWalkChoice
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Ready to start?")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                    Text("Participant ID: \(setup.trimmedID.isEmpty ? "Not entered" : setup.trimmedID)")
                    Text(choice.title).font(.headline)
                    Text("Starting place: \(choice.startingPlace)")
                    Text("Destination: \(choice.destination)")
                    Text("Start at the starting point. Your first instruction will play automatically when your arrival is detected.")
                    if let problem = setup.startProblem(for: choice, authorization: session.authorizationStatus) {
                        Text(problem).foregroundStyle(.red)
                    }
                    Button {
                        setup.confirm(authorization: session.authorizationStatus)
                    } label: {
                        Text("Start walk")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.startProblem(for: choice, authorization: session.authorizationStatus) != nil)
                    .accessibilityIdentifier("participant.start")
                    Button { setup.cancel() } label: {
                        Text("Cancel").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Review walk")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { headingFocused = true }
        }
    }
}
