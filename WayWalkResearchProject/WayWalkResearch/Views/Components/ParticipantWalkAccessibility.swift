import Foundation

/// A small announcement policy, independent of VoiceOver so queue timing and
/// deduplication can be tested without a device's screen reader running.
struct ParticipantWalkAnnouncements {
    struct Snapshot: Equatable {
        var isActive: Bool
        var routeIsComplete: Bool
        var isPlaying: Bool
        var loggingFailed: Bool
        var locationFailed: Bool
        var permissionMissing: Bool

        @MainActor
        init(session: WalkSession) {
            isActive = session.isActive
            routeIsComplete = session.routeIsComplete
            isPlaying = session.nowPlayingWaypointID != nil
            loggingFailed = session.loggingError != nil
            locationFailed = session.locationError != nil
            permissionMissing = ParticipantSetup.permissionMessage(session.authorizationStatus) != nil
        }

        init(isActive: Bool = true, routeIsComplete: Bool = false, isPlaying: Bool = false,
             loggingFailed: Bool = false, locationFailed: Bool = false, permissionMissing: Bool = false) {
            self.isActive = isActive
            self.routeIsComplete = routeIsComplete
            self.isPlaying = isPlaying
            self.loggingFailed = loggingFailed
            self.locationFailed = locationFailed
            self.permissionMissing = permissionMissing
        }
    }

    static let completion = "Walk complete. All instructions have finished. Use End walk to save and review your session."
    static let loggingFailure = "Your walk data could not be saved. End the walk and contact your researcher."
    static let locationFailure = "Location tracking has a problem. Instructions may not play. Stop walking until location tracking returns, or end the walk."
    static let permissionFailure = "Location access is unavailable. Instructions cannot track your arrival. End the walk and check location access in Settings."

    private var announcedFailures: Set<String> = []
    private(set) var announcedCompletion = false

    mutating func messages(for state: Snapshot) -> [String] {
        var failures: [String] = []
        if state.loggingFailed { failures.append(Self.loggingFailure) }
        if state.permissionMissing { failures.append(Self.permissionFailure) }
        else if state.locationFailed { failures.append(Self.locationFailure) }
        // A resolved failure can be announced again if it recurs later.
        announcedFailures.formIntersection(Set(failures))
        guard state.isActive, !state.isPlaying else { return [] }
        var messages = failures.filter { !announcedFailures.contains($0) }
        announcedFailures.formUnion(failures)
        if state.routeIsComplete && !announcedCompletion {
            announcedCompletion = true
            messages.append(Self.completion)
        }
        return messages
    }
}
