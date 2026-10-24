import XCTest
@testable import WayWalkResearch

final class ParticipantWalkAccessibilityTests: XCTestCase {
    func testRoutineWalkingAndPlaybackAreSilent() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertTrue(policy.messages(for: .init()).isEmpty)
        XCTAssertTrue(policy.messages(for: .init(isPlaying: true)).isEmpty)
        XCTAssertTrue(policy.messages(for: .init()).isEmpty)
    }

    func testCompletionWaitsForPlaybackAndIsAnnouncedOnce() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertTrue(policy.messages(for: .init(routeIsComplete: true, isPlaying: true)).isEmpty)
        XCTAssertFalse(policy.announcedCompletion)
        XCTAssertEqual(policy.messages(for: .init(routeIsComplete: true)), [ParticipantWalkAnnouncements.completion])
        XCTAssertTrue(policy.messages(for: .init(routeIsComplete: true)).isEmpty)
    }

    func testFailuresAreDeferredDuringPlaybackAndDeduplicatedUntilResolved() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertTrue(policy.messages(for: .init(isPlaying: true, loggingFailed: true)).isEmpty)
        XCTAssertEqual(policy.messages(for: .init(loggingFailed: true)), [ParticipantWalkAnnouncements.loggingFailure])
        XCTAssertTrue(policy.messages(for: .init(loggingFailed: true)).isEmpty)
        XCTAssertTrue(policy.messages(for: .init()).isEmpty)
        XCTAssertEqual(policy.messages(for: .init(loggingFailed: true)), [ParticipantWalkAnnouncements.loggingFailure])
    }

    func testResolvedFailureDuringPlaybackIsNotAnnouncedLater() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertTrue(policy.messages(for: .init(isPlaying: true, locationFailed: true)).isEmpty)
        XCTAssertTrue(policy.messages(for: .init()).isEmpty)
    }

    func testPermissionFailureAvoidsDuplicateLocationMessage() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertEqual(policy.messages(for: .init(locationFailed: true, permissionMissing: true)),
                       [ParticipantWalkAnnouncements.permissionFailure])
    }

    func testEndingEarlyDoesNotAnnounceCompletion() {
        var policy = ParticipantWalkAnnouncements()
        XCTAssertTrue(policy.messages(for: .init(isActive: false, routeIsComplete: true)).isEmpty)
        XCTAssertFalse(policy.announcedCompletion)
    }

    @MainActor
    func testRealSessionQueueMustDrainBeforeCompletionAnnouncement() async throws {
        let player = FakePromptPlayer()
        let session = WalkSession(audioPlayer: player, locationManager: SilentLocationManager())
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly, participantID: "ACCESSIBILITY", mode: .test)
        defer { session.end() }
        session.authorizationStatus = .authorizedAlways
        var policy = ParticipantWalkAnnouncements()
        let count = walk.routeLength(for: .navigationOnly)
        for _ in 0..<count { session.playCurrentWaypoint() }
        XCTAssertTrue(session.routeIsComplete)
        XCTAssertTrue(policy.messages(for: .init(session: session)).isEmpty)
        for _ in 0..<(count - 1) { player.finishOldest() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(session.nowPlayingWaypointID)
        XCTAssertTrue(policy.messages(for: .init(session: session)).isEmpty)
        player.finishOldest()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.nowPlayingWaypointID)
        XCTAssertEqual(policy.messages(for: .init(session: session)), [ParticipantWalkAnnouncements.completion])
        XCTAssertTrue(policy.messages(for: .init(session: session)).isEmpty)
    }
}
