import SwiftUI

@main
struct WayWalkResearchApp: App {
    var body: some Scene {
        WindowGroup {
            SelectView {
                HomeView()
            } participant: {
                ParticipantHomeView()
            }
        }
    }
}
