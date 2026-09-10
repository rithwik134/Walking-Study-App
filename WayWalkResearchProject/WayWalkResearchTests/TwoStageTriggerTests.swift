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

    /// Walk A as this session actually walks it. `a2` carries no navigation
    /// script, so under Navigation Only it is off-route and `armNextWaypoint()`
    /// skips it — `walk.waypoints[1]` is a waypoint these tests can never
    /// reach. Filtering the same way the session does keeps "the next
    /// waypoint" meaning the next one that fires.
    private var routeWaypoints: [Waypoint] {
        walk.waypoints.filter { $0.isOnRoute(for: .navigationOnly) }
    }

    private var wp1: Waypoint { routeWaypoints[0] }
    private var wp2: Waypoint { routeWaypoints[1] }

    /// Cues forward with the researcher failsafe until `id` is the armed
    /// waypoint, without firing it. Uses only the real delivery path, so the
    /// queue advances exactly as it would on a walk — including the skips.
    private func cueForward(in walk: Walk, to id: String) {
        for _ in 0...walk.waypoints.count {
            let armed = walk.waypoints[session.currentWaypointNumber - 1]
            if armed.id == id { return }
            session.playCurrentWaypoint()
        }
        XCTFail("never reached \(id)")
    }

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
        XCTAssertEqual(session.currentWaypointNumber, wp2.order, "should have advanced to the next on-route waypoint")
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
        XCTAssertEqual(session.currentWaypointNumber, wp2.order, "the walk must be unblocked")
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
        XCTAssertEqual(session.currentWaypointNumber, wp2.order)
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

    /// `closest_approach_m` and `trigger_distance_m` answer different
    /// questions, and on a backstop row they diverge sharply.
    ///
    /// This is the case that motivates the second column: closest approach
    /// says "they passed within 20m", which reads like a clean trigger, while
    /// the prompt in fact played once they were 80m away. For a navigation
    /// instruction that difference is the whole story.
    func testBackstopRowsShowWhereTheyActuallyWereWhenItPlayed() async throws {
        await deliver([fix(wp1, metres: 20)])
        await deliver([fix(wp1, metres: 80)])
        await deliver([fix(wp1, metres: 85)])

        let row = try XCTUnwrap(triggerRows.first)
        let closest = try XCTUnwrap(row.closestApproachMetres)
        let atFire = try XCTUnwrap(row.triggerDistanceMetres)

        XCTAssertEqual(closest, 20, accuracy: 2, "closest approach is the minimum over the approach")
        XCTAssertEqual(atFire, 85, accuracy: 3, "trigger distance is where they were when it played")
        XCTAssertGreaterThan(atFire, closest + 50, "the two must not be conflated")
    }

    /// On a clean fire the two agree, because the fire happens at the closest
    /// point. That is what makes the divergence above meaningful.
    func testCleanFiresHaveMatchingCloseAndAtFireDistances() async throws {
        await deliver([fix(wp1, metres: 4), fix(wp1, metres: 4)])

        let row = try XCTUnwrap(triggerRows.first)
        let closest = try XCTUnwrap(row.closestApproachMetres)
        let atFire = try XCTUnwrap(row.triggerDistanceMetres)
        XCTAssertLessThanOrEqual(atFire, wp1.triggerRadius)
        XCTAssertEqual(atFire, closest, accuracy: 1)
    }

    /// A forced prompt records how far away they were when the researcher
    /// pressed the button — the number that says whether it was cued sensibly.
    func testManualFiresRecordTheDistanceAtTheMomentOfPressing() async throws {
        await deliver([fix(wp1, metres: 120)])
        session.playCurrentWaypoint()

        let row = try XCTUnwrap(triggerRows.first)
        XCTAssertEqual(try XCTUnwrap(row.triggerDistanceMetres), 120, accuracy: 3)
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

    // MARK: - Condition-branched routes
    //
    // The two conditions cross Gordon Square by different paths, encoded as
    // waypoints carrying a script for one condition only: `a10` navigation,
    // `a11` contextual. A waypoint off the running condition's route is skipped
    // at arm time — never armed, never spoken, never logged.
    //
    // The bug these cover: arming `a11` during a Navigation Only walk blocked
    // the entire rest of Walk A. `a11` sits ~33m away across the square, so no
    // fix ever landed inside its 10m radius, and the recede backstop could not
    // rescue it either — the seeded closest approach already exceeded
    // `backstopApproachDistance`, so its guard never opened.

    /// Firing `a10` must arm `a12`, stepping straight over the contextual
    /// branch. Nothing about `a11` may reach the CSV.
    func testTheContextualBranchIsSkippedUnderNavigationOnly() async throws {
        let a10 = try XCTUnwrap(walk.waypoints.first { $0.id == "a10" })
        cueForward(in: walk, to: "a10")

        await deliver([fix(a10, metres: 3), fix(a10, metres: 3)])

        XCTAssertEqual(triggerRows.last?.waypointID, "a10")
        XCTAssertEqual(session.currentWaypointNumber, 12, "a11 must have been stepped over")
        XCTAssertFalse(triggerRows.contains { $0.waypointID == "a11" },
                       "a11 is off this route — it must not appear in the log at all")

        // And the walk keeps moving: a12 is armed and fires normally.
        let a12 = try XCTUnwrap(walk.waypoints.first { $0.id == "a12" })
        await deliver([fix(a12, metres: 3), fix(a12, metres: 3)])
        XCTAssertEqual(triggerRows.last?.waypointID, "a12")
    }

    /// The mirror image: under Navigation + Context the *navigation* branch is
    /// the one that must not fire. Before the fallback in `script(for:)` was
    /// removed, `a10` fired here and read out its navigation turn — sending the
    /// participant the wrong way round the square, in a synthesised voice,
    /// because no `a10_context.mp3` exists to play.
    func testTheNavigationBranchIsSkippedUnderNavigationPlusContext() async throws {
        session.start(walk: walk, informationLevel: .navigationPlusContext,
                      participantID: "TWOSTAGE", mode: .test)
        let a9 = try XCTUnwrap(walk.waypoints.first { $0.id == "a9" })
        cueForward(in: walk, to: "a9")

        await deliver([fix(a9, metres: 3), fix(a9, metres: 3)])

        XCTAssertEqual(session.currentWaypointNumber, 11, "a10 must have been stepped over")

        // Standing squarely on a10 must still say nothing.
        let a10 = try XCTUnwrap(walk.waypoints.first { $0.id == "a10" })
        await deliver([fix(a10, metres: 1), fix(a10, metres: 1)])
        XCTAssertFalse(triggerRows.contains { $0.waypointID == "a10" },
                       "a10 is off the contextual route")
        XCTAssertFalse(player.scripts.contains(a10.navigationPrompt),
                       "a10's navigation script must never be spoken in this condition")
    }

    /// Walk B's Gordon Square branch, which has no contextual counterpart —
    /// `b20`'s script carries the contextual route through the square instead.
    func testWalkBNavigationBranchIsSkippedUnderNavigationPlusContext() async throws {
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        session.start(walk: walkB, informationLevel: .navigationPlusContext,
                      participantID: "TWOSTAGE", mode: .test)
        let b20 = try XCTUnwrap(walkB.waypoints.first { $0.id == "b20" })
        cueForward(in: walkB, to: "b20")

        await deliver([fix(b20, metres: 3), fix(b20, metres: 3)])

        XCTAssertEqual(session.currentWaypointNumber, 22, "b21 must have been stepped over")
        XCTAssertFalse(triggerRows.contains { $0.waypointID == "b21" })
    }

    /// Skipping must not fire, speak, or advance past a waypoint that *is* on
    /// the route — the failure mode would be a whole leg silently consumed.
    func testSkippingStopsAtTheFirstOnRouteWaypoint() async throws {
        // a1 fires; a2 is off-route; a3 is on-route and must be what arms.
        await deliver([fix(wp1, metres: 3), fix(wp1, metres: 3)])

        XCTAssertEqual(session.currentWaypointNumber, 3)
        XCTAssertEqual(triggerRows.count, 1, "only a1 fired")
        let region = try XCTUnwrap(manager.monitoredRegion as? CLCircularRegion)
        XCTAssertEqual(region.identifier, "a3")
    }

    /// Manual mode skips too: the researcher must not be asked to press Play on
    /// a waypoint that would say nothing.
    func testManualModeSkipsOffRouteWaypointsAsWell() async throws {
        try startSession(mode: .manual)

        session.playCurrentWaypoint()
        XCTAssertEqual(triggerRows.map(\.waypointID), ["a1"])
        XCTAssertEqual(session.currentWaypointNumber, 3, "a2 must not be offered")

        session.playCurrentWaypoint()
        XCTAssertEqual(triggerRows.map(\.waypointID), ["a1", "a3"])
    }
}
