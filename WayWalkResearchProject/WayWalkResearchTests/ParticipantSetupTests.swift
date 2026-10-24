import XCTest
import CoreLocation
@testable import WayWalkResearch

@MainActor
final class ParticipantSetupTests: XCTestCase {
    private func session(status: CLAuthorizationStatus = .authorizedAlways) -> WalkSession {
        let session = WalkSession(audioPlayer: FakePromptPlayer(), locationManager: SilentLocationManager())
        session.authorizationStatus = status
        return session
    }

    func testAllFourChoicesLaunchCorrectStudySessionAfterDismissal() throws {
        XCTAssertEqual(ParticipantWalkChoice.all.count, 4)
        XCTAssertEqual(Set(ParticipantWalkChoice.all).count, 4)
        for choice in ParticipantWalkChoice.all {
            let setup = ParticipantSetup()
            let session = session()
            defer { session.end() }
            setup.participantID = "  P03  "
            setup.select(choice)
            XCTAssertNil(session.logger, "browsing cannot create a CSV")
            setup.confirm(authorization: session.authorizationStatus)
            XCTAssertNil(session.logger, "wait until the sheet has dismissed")
            XCTAssertTrue(setup.confirmationDismissed(session: session))
            XCTAssertEqual(session.logger?.metadata.participantID, "P03")
            XCTAssertEqual(session.logger?.metadata.walkID, choice.walkID)
            XCTAssertEqual(session.informationLevel, choice.level)
            XCTAssertEqual(session.sessionMode, .study)
            XCTAssertFalse(session.awaitingFirstManualTrigger)
            XCTAssertEqual(setup.activeLaunch?.choice, choice)
        }
    }

    func testCancelCreatesNoSessionAndRetainsID() {
        let setup = ParticipantSetup()
        let session = session()
        setup.participantID = "P04"
        setup.select(ParticipantWalkChoice.all[0])
        setup.cancel()
        XCTAssertFalse(setup.confirmationDismissed(session: session))
        XCTAssertNil(session.logger)
        XCTAssertNil(setup.activeLaunch)
        XCTAssertEqual(setup.participantID, "P04")
    }

    func testBlankIDCanBrowseButCannotStart() {
        let setup = ParticipantSetup()
        let session = session()
        setup.participantID = " \n "
        setup.select(ParticipantWalkChoice.all[0])
        XCTAssertNotNil(setup.confirmation)
        setup.confirm(authorization: .authorizedAlways)
        XCTAssertNotNil(setup.error)
        XCTAssertFalse(setup.confirmationDismissed(session: session))
        XCTAssertNil(session.logger)
    }

    func testMissingRouteCannotBeSelectedOrStarted() {
        let setup = ParticipantSetup(loadWalk: { _ in nil })
        setup.participantID = "P05"
        for choice in ParticipantWalkChoice.all {
            XCTAssertNotNil(setup.unavailableMessage(for: choice))
            setup.select(choice)
            XCTAssertNil(setup.confirmation)
        }
    }

    func testDeniedRestrictedAndUndeterminedPermissionsBlockStart() {
        for status in [CLAuthorizationStatus.denied, .restricted, .notDetermined] {
            let setup = ParticipantSetup()
            let session = session(status: status)
            setup.participantID = "P06"
            setup.select(ParticipantWalkChoice.all[0])
            setup.confirm(authorization: status)
            XCTAssertNotNil(setup.error)
            XCTAssertFalse(setup.confirmationDismissed(session: session))
            XCTAssertNil(session.logger)
        }
        XCTAssertNil(ParticipantSetup.permissionMessage(.authorizedWhenInUse))
        XCTAssertNil(ParticipantSetup.permissionMessage(.authorizedAlways))
    }

    func testPermissionRevokedDuringDismissalDoesNotCreateSession() {
        let setup = ParticipantSetup()
        let session = session()
        setup.participantID = "P07"
        setup.select(ParticipantWalkChoice.all[0])
        setup.confirm(authorization: .authorizedAlways)
        session.authorizationStatus = .denied
        XCTAssertFalse(setup.confirmationDismissed(session: session))
        XCTAssertNotNil(setup.error)
        XCTAssertNil(session.logger)
        XCTAssertNil(setup.activeLaunch)
    }

    func testRepeatedStartAndDismissalCannotReplaceRunningSession() {
        let setup = ParticipantSetup()
        let session = session()
        defer { session.end() }
        setup.participantID = "P08"
        setup.select(ParticipantWalkChoice.all[0])
        setup.confirm(authorization: .authorizedAlways)
        setup.confirm(authorization: .authorizedAlways)
        XCTAssertTrue(setup.confirmationDismissed(session: session))
        let logger = session.logger
        setup.select(ParticipantWalkChoice.all[1])
        setup.confirm(authorization: .authorizedAlways)
        XCTAssertFalse(setup.confirmationDismissed(session: session))
        XCTAssertTrue(session.logger === logger)
        XCTAssertEqual(session.logger?.events.count, 1)
    }

    func testReturnAllowsAnotherWalkWithoutLosingParticipantID() {
        let setup = ParticipantSetup()
        let session = session()
        defer { session.end() }
        setup.participantID = "P09"
        setup.select(ParticipantWalkChoice.all[0])
        setup.confirm(authorization: .authorizedAlways)
        XCTAssertTrue(setup.confirmationDismissed(session: session))
        session.end()
        setup.activeLaunch = nil
        setup.select(ParticipantWalkChoice.all[2])
        setup.confirm(authorization: .authorizedAlways)
        XCTAssertTrue(setup.confirmationDismissed(session: session))
        XCTAssertEqual(setup.participantID, "P09")
        XCTAssertEqual(session.logger?.metadata.walkID, .walkB)
    }
}
