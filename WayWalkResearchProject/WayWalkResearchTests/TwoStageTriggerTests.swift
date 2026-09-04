import XCTest
import CoreLocation
@testable import WayWalkResearch

/// Covers the two-stage trigger: a coarse `CLCircularRegion` that only wakes
/// the app, and a fire decision made from the location fix stream.
///
/// The headline test here is `testWakeRegionEntryNeverFiresAnything`. Real
/// devices report region entry from up to ~100m away, and with waypoints a
/// median ~50m apart the old design chain-fired several prompts at a
/// participant standing still — the failure this whole design exists to
/// prevent. Everything else guards the machinery that replaced it.
@MainActor
final class TwoStageTriggerTests: XCTestCase {

    private var session: WalkSession!
    private var player: FakePromptPlayer!
    private var manager: SilentLocationManager!
    private var walk: Walk!

    private func startSession(
        mode: SessionMode = .test,
        tuning: TriggerTuning = TriggerTuning()
    ) throws {
        player = FakePromptPlayer()
        manager = SilentLocationManager()
        session = WalkSession(audioPlayer: player, locationManager: manager, tuning: tuning)
        walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly,
                      participantID: "TWOSTAGE", mode: mode)
    }

    override func setUpWithError() throws {
        try startSession()
    }

    override func tearDownWithError() throws {
        session = nil
        player = nil
        manager = nil
        walk = nil
    }

    // MARK: - Helpers

    /// A fix a given distance due north of a waypoint.
    private func fix(
        _ waypoint: Waypoint,
        metres: Double,
        accuracy: CLLocationAccuracy = 5,
        timestamp: Date = Date()
    ) -> CLLocation {
        let degreesPerMetre = 1.0 / 111_320.0
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: waypoint.latitude + metres * degreesPerMetre,
                longitude: waypoint.longitude
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: timestamp
        )
    }

    private func deliver(_ locations: [CLLocation]) async {
        session.locationManager(CLLocationManager(), didUpdateLocations: locations)
        await settle()
    }

    /// Region callbacks hop to the main actor; let that land.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    private var triggerRows: [SessionEvent] {
        session.logger?.events.filter { $0.type == .waypointTrigger } ?? []
    }

    private var wp1: Waypoint { walk.waypoints[0] }
    private var wp2: Waypoint { walk.waypoints[1] }

    // MARK: - The chain-fire regression

    /// **The test this file exists for.** Region entry, however it is reported
    /// and however often, must never deliver a prompt.
    ///
    /// On a real device iOS reports "inside" from up to ~100m out, and answers
    /// the arm-time `requestState` immediately because the participant is
    /// usually already within the wake radius of the next waypoint. Under the
    /// previous design each of those replies started a dwell that fired a
    /// prompt, so a single arrival cascaded through several waypoints.
    func testWakeRegionEntryNeverFiresAnything() async throws {
        // Every way the region can claim the participant is inside, repeatedly.
        manager.simulateEnter()
        await settle()
        manager.simulateState(.inside)
        await settle()
        manager.simulateEnter()
        manager.simulateState(.inside)
        await settle()

        // Plus a real fix, but a long way out — nothing here justifies firing.
        await deliver([fix(wp1, metres: 60)])

        XCTAssertTrue(triggerRows.isEmpty, "region entry must not fire a prompt")
        XCTAssertTrue(player.scripts.isEmpty, "nothing should have been spoken")
        XCTAssertEqual(session.currentWaypointNumber, 1, "the walk must not have advanced")
        XCTAssertTrue(session.hasEnteredWakeRegion, "entry should still be recorded")
    }

    /// The monitored region is the coarse wake radius, not the waypoint's own
    /// fire threshold — the two are deliberately different numbers now.
    func testMonitoredRegionUsesTheWakeRadiusNotTheTriggerRadius() throws {
        let region = try XCTUnwrap(manager.monitoredRegion as? CLCircularRegion)
        XCTAssertEqual(region.radius, session.tuning.wakeRadius)
        XCTAssertNotEqual(region.radius, wp1.triggerRadius)
        XCTAssertEqual(region.identifier, wp1.id)
        XCTAssertFalse(manager.requestedStates.isEmpty,
                       "arm-time requestState should still be issued — it is harmless now")
    }

    // MARK: - The fine trigger

    func testTwoConsecutiveCloseFixesFireThePrompt() async throws {
        await deliver([fix(wp1, metres: 4)])
        XCTAssertTrue(triggerRows.isEmpty, "one fix alone must not fire")

        await deliver([fix(wp1, metres: 4)])
        XCTAssertEqual(triggerRows.count, 1)
        XCTAssertEqual(triggerRows.first?.triggerSource, .automatic)
        XCTAssertNil(triggerRows.first?.note, "a normal fire carries no backstop note")
        XCTAssertEqual(session.currentWaypointNumber, 2, "should have advanced")
    }

    /// A coalesced batch must fire without waiting on any wall clock. This is
    /// what the old 2-second dwell cost: while locked, fixes arrive in bursts
    /// already seconds old, so adding delay only made a late prompt later.
    func testABatchFiresWithoutWaitingForWallClock() async throws {
        await deliver([fix(wp1, metres: 3), fix(wp1, metres: 2)])
        XCTAssertEqual(triggerRows.count, 1, "both fixes in one batch should confirm immediately")
    }

    /// A single close fix must not be enough.
    ///
    /// This is also what protects `ClosestApproachTests`, several of which
    /// deliver one accurate fix at or near a waypoint and then expect
    /// `playCurrentWaypoint()` to produce the only row. Lowering
    /// `confirmingFixCount` to 1 breaks those tests — deliberately, so the
    /// coupling is discovered here rather than there.
    func testOneCloseFixIsNotEnoughButWouldBeWithKOfOne() async throws {
        await deliver([fix(wp1, metres: 3)])
        XCTAssertTrue(triggerRows.isEmpty)

        // Same single fix, k = 1: fires. The difference is the tuning, nothing else.
        try startSession(tuning: TriggerTuning(confirmingFixCount: 1))
        await deliver([fix(wp1, metres: 3)])
        XCTAssertEqual(triggerRows.count, 1)
    }

    func testFixesTooImpreciseToBelieveNeverFire() async throws {
        // Sitting on the waypoint, but with an error bar far wider than the
        // radius — that is not evidence of being within 10m.
        for _ in 0..<5 {
            await deliver([fix(wp1, metres: 1, accuracy: 40)])
        }
        XCTAssertTrue(triggerRows.isEmpty)
    }

    func testLeavingTheRadiusResetsTheRun() async throws {
        await deliver([fix(wp1, metres: 4)])
        await deliver([fix(wp1, metres: 30)])
        await deliver([fix(wp1, metres: 4)])
        XCTAssertTrue(triggerRows.isEmpty, "the run must be re-earned from scratch")

        await deliver([fix(wp1, metres: 4)])
        XCTAssertEqual(triggerRows.count, 1)
    }

    /// An unusable fix is not evidence in either direction, so it must neither
    /// confirm arrival nor break a run built from good fixes.
    func testAnUnusableFixNeitherConfirmsNorResets() async throws {
        await deliver([fix(wp1, metres: 4)])
        await deliver([fix(wp1, metres: 1, accuracy: 400)])
        await deliver([fix(wp1, metres: 4)])
        XCTAssertEqual(triggerRows.count, 1, "the ±400m fix should have been skipped entirely")
    }

    /// Firing mid-batch re-arms, so later fixes are evaluated against the next
    /// waypoint. That is correct catch-up through a batched approach — and it
    /// can only fire again when the participant genuinely was within the next
    /// waypoint's radius too.
    func testCatchUpThroughABatchIsAllowedButNotChainFiring() async throws {
        await deliver([
            fix(wp1, metres: 3), fix(wp1, metres: 3),   // fires waypoint 1
            fix(wp2, metres: 50)                         // nowhere near waypoint 2
        ])
        XCTAssertEqual(triggerRows.count, 1, "a distant fix must not fire the next waypoint")

        await deliver([fix(wp2, metres: 3), fix(wp2, metres: 3)])
        XCTAssertEqual(triggerRows.count, 2, "genuinely arriving at waypoint 2 should fire it")
    }

    // MARK: - Backstops

    func testWakeExitFiresTheWaypointItPassed() async throws {
        manager.simulateEnter()
        await settle()
        await deliver([fix(wp1, metres: 40)])   // never close enough to confirm
        XCTAssertTrue(triggerRows.isEmpty)

        manager.simulateExit()
        await settle()

        XCTAssertEqual(triggerRows.count, 1)
        XCTAssertEqual(triggerRows.first?.triggerSource, .automatic)
        XCTAssertEqual(triggerRows.first?.note, "backstop: wake_exit")
        XCTAssertEqual(session.currentWaypointNumber, 2, "the walk must be unblocked")
    }

    /// You cannot have passed what you never reached.
    func testWakeExitWithoutEntryFiresNothing() async throws {
        manager.simulateExit()
        await settle()
        XCTAssertTrue(triggerRows.isEmpty)
    }

    func testRecedingWellPastACloseApproachFires() async throws {
        await deliver([fix(wp1, metres: 20)])           // close, but outside 10m
        await deliver([fix(wp1, metres: 80)])           // 80 >= 20 + 50
        XCTAssertTrue(triggerRows.isEmpty, "one receding fix is not enough")

        await deliver([fix(wp1, metres: 85)])
        XCTAssertEqual(triggerRows.count, 1)
        XCTAssertEqual(triggerRows.first?.note, "backstop: receded")
    }

    /// Guards a dogleg: `closestApproachToArmed` is seeded at arm time from
    /// the last known fix, so a participant rounding a corner can appear to
    /// recede without ever having approached. Requiring a genuinely close
    /// approach first is what makes that implausible.
    func testRecedingFromADistantClosestApproachDoesNotFire() async throws {
        await deliver([fix(wp1, metres: 45)])           // never within 30m
        await deliver([fix(wp1, metres: 100)])
        await deliver([fix(wp1, metres: 110)])
        XCTAssertTrue(triggerRows.isEmpty)
    }

    /// The backstop must work with fixes *too poor to fire on* — that is the
    /// entire situation it exists for.
    ///
    /// Regression test for a real bug: the accuracy gate for the fine trigger
    /// originally sat at the top of `evaluateTrigger`, so a fix worse than
    /// `triggerAccuracyLimit` returned before the backstop was ever consulted.
    /// A simulated walk with every fix at ±40m fired *nothing at all* and the
    /// walk stalled on waypoint 1. The unit suite missed it entirely because
    /// every backstop test used accurate fixes.
    func testRecedeBackstopWorksWithFixesTooPoorToFireOn() async throws {
        // Well outside `triggerAccuracyLimit` (25m), inside the 50m limit that
        // closest approach itself is measured with.
        let poor: CLLocationAccuracy = 40

        await deliver([fix(wp1, metres: 20, accuracy: poor)])
        await deliver([fix(wp1, metres: 80, accuracy: poor)])
        await deliver([fix(wp1, metres: 85, accuracy: poor)])

        XCTAssertEqual(triggerRows.count, 1, "the walk must not stall on poor accuracy")
        XCTAssertEqual(triggerRows.first?.note, "backstop: receded")
    }

    /// …but a fix too poor even to measure with must not drive the backstop
    /// either, or the comparison against `closest_approach_m` is meaningless.
    func testRecedeBackstopIgnoresFixesTooPoorToMeasureWith() async throws {
        await deliver([fix(wp1, metres: 20)])
        await deliver([fix(wp1, metres: 80, accuracy: 400)])
        await deliver([fix(wp1, metres: 85, accuracy: 400)])
        XCTAssertTrue(triggerRows.isEmpty)
    }

    func testRecedeBackstopCanBeDisabled() async throws {
        try startSession(tuning: TriggerTuning(isRecedeBackstopEnabled: false))
        await deliver([fix(wp1, metres: 20)])
        await deliver([fix(wp1, metres: 80)])
        await deliver([fix(wp1, metres: 85)])
        XCTAssertTrue(triggerRows.isEmpty)
    }

    // MARK: - Modes

    /// Manual mode's contract: nothing plays until the researcher presses the
    /// button — but the cue hint still tracks the radius.
    func testManualModeNeverAutoFiresButStillLightsTheCue() async throws {
        try startSession(mode: .manual)

        await deliver([fix(wp1, metres: 3), fix(wp1, metres: 3)])
        XCTAssertTrue(triggerRows.isEmpty, "manual mode must not fire on arrival")
        XCTAssertTrue(session.isInsideCurrentRadius, "but the cue button should be green")

        await deliver([fix(wp1, metres: 40)])
        XCTAssertFalse(session.isInsideCurrentRadius)

        // Neither backstop may fire either.
        manager.simulateEnter()
        await settle()
        manager.simulateExit()
        await settle()
        XCTAssertTrue(triggerRows.isEmpty)
    }

    /// The failsafe is unconditional — that is the whole point of it.
    func testPlayCurrentWaypointStillWorksFarFromTheWaypoint() async throws {
        await deliver([fix(wp1, metres: 300)])
        XCTAssertFalse(session.isInsideCurrentRadius)

        session.playCurrentWaypoint()

        XCTAssertEqual(triggerRows.count, 1)
        XCTAssertEqual(triggerRows.first?.triggerSource, .manual)
        XCTAssertEqual(session.currentWaypointNumber, 2)
    }

    // MARK: - Invariants

    /// Whichever path delivered, no confirmation progress may survive into the
    /// next waypoint. Progress left set is what used to wedge the walk.
    func testEveryDeliveryPathLeavesNoConfirmationProgress() async throws {
        // Automatic
        await deliver([fix(wp1, metres: 3), fix(wp1, metres: 3)])
        XCTAssertFalse(session.isConfirmingArrival)
        XCTAssertFalse(session.isInsideCurrentRadius)
        XCTAssertFalse(session.hasEnteredWakeRegion, "a fresh waypoint has not been approached")

        // Backstop
        manager.simulateEnter()
        await settle()
        manager.simulateExit()
        await settle()
        XCTAssertFalse(session.isConfirmingArrival)
        XCTAssertFalse(session.isInsideCurrentRadius)

        // Manual
        session.playCurrentWaypoint()
        XCTAssertFalse(session.isConfirmingArrival)
        XCTAssertFalse(session.isInsideCurrentRadius)
    }

    /// The row must describe the fix that caused it, not some other one.
    func testTheFiringFixIsTheOneLogged() async throws {
        let old = Date(timeIntervalSinceNow: -30)
        let recent = Date(timeIntervalSinceNow: -2)

        await deliver([
            fix(wp1, metres: 3, timestamp: old),
            fix(wp1, metres: 3, timestamp: recent)
        ])

        let row = try XCTUnwrap(triggerRows.first)
        XCTAssertEqual(row.fixTimestamp, recent, "should log the fix that completed the run")
        // …and the position must come from that same fix.
        XCTAssertEqual(row.latitude ?? 0, session.currentLatitude ?? 0, accuracy: 0.000001)
    }

    /// A batched delivery is exactly when a stale fix can be logged, so the
    /// age must be visible rather than silently absent.
    func testFixAgeIsRecordedForABatchedFire() async throws {
        let stale = Date(timeIntervalSinceNow: -25)
        await deliver([fix(wp1, metres: 3, timestamp: stale), fix(wp1, metres: 3, timestamp: stale)])

        let row = try XCTUnwrap(triggerRows.first)
        let age = try XCTUnwrap(row.fixTimestamp.map { row.timestamp.timeIntervalSince($0) })
        XCTAssertGreaterThan(age, 20, "a 25s-old fix should report a large age")
    }
}
