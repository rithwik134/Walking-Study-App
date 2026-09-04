import XCTest
import CoreLocation
@testable import WayWalkResearch

/// Verifies `closest_approach_m` — the column used to size trigger radii.
///
/// Driven by calling the `CLLocationManagerDelegate` method directly with
/// hand-built fixes, so every distance is known exactly rather than inferred
/// from simulated GPS. A radius chosen from a wrong number is worse than one
/// chosen from no number, so these check the value is a true minimum, is
/// scoped to the right waypoint, and is blank rather than misleading when it
/// cannot be trusted.
/// A location manager that never emits anything of its own, so the only fixes
/// a test sees are the ones it delivers. Without this the simulator's own
/// location leaks into the session — and if it happens to sit on a route
/// waypoint, a distance assertion silently reads 0.
final class SilentLocationManager: LocationProviding {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var showsBackgroundLocationIndicator = false
    private(set) var monitoredRegions: Set<CLRegion> = []
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways

    /// Every region `WalkSession` has asked the state of, in order. Lets a
    /// test assert the arm-time `requestState` still happens — and, crucially,
    /// that its "inside" reply no longer fires anything.
    private(set) var requestedStates: [CLRegion] = []

    /// The single armed region. `WalkSession` monitors exactly one at a time.
    var monitoredRegion: CLRegion? { monitoredRegions.first }

    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startMonitoring(for region: CLRegion) { monitoredRegions.insert(region) }
    func stopMonitoring(for region: CLRegion) { monitoredRegions.remove(region) }

    /// Records the request but never answers it. Region state is *the* thing
    /// under test in the two-stage design, so it is delivered explicitly by
    /// `simulate…` below rather than arriving on its own.
    func requestState(for region: CLRegion) { requestedStates.append(region) }

    // MARK: - Driving region callbacks

    // `WalkSession` ignores the manager argument on all three, so a throwaway
    // real one satisfies the signature — the same trick the fix delivery
    // helper uses.

    func simulateEnter(_ region: CLRegion? = nil) {
        guard let region = region ?? monitoredRegion else { return }
        delegate?.locationManager?(CLLocationManager(), didEnterRegion: region)
    }

    func simulateExit(_ region: CLRegion? = nil) {
        guard let region = region ?? monitoredRegion else { return }
        delegate?.locationManager?(CLLocationManager(), didExitRegion: region)
    }

    func simulateState(_ state: CLRegionState, for region: CLRegion? = nil) {
        guard let region = region ?? monitoredRegion else { return }
        delegate?.locationManager?(CLLocationManager(), didDetermineState: state, for: region)
    }
}

@MainActor
final class ClosestApproachTests: XCTestCase {

    private var session: WalkSession!
    private var player: FakePromptPlayer!
    private var walk: Walk!

    /// walkA waypoint 1, the target for every distance below.
    private let waypoint1 = CLLocation(latitude: 51.524329, longitude: -0.134513)

    override func setUpWithError() throws {
        player = FakePromptPlayer()
        session = WalkSession(audioPlayer: player, locationManager: SilentLocationManager())
        walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly,
                      participantID: "APPROACH", mode: .test)
    }

    override func tearDownWithError() throws {
        session = nil
        player = nil
        walk = nil
    }

    // MARK: - Helpers

    /// A fix a given distance due north of waypoint 1.
    private func fix(metresNorth: Double, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        let degreesPerMetre = 1.0 / 111_320.0
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: waypoint1.coordinate.latitude + metresNorth * degreesPerMetre,
                longitude: waypoint1.coordinate.longitude
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: Date()
        )
    }

    private func deliver(_ locations: [CLLocation]) async {
        session.locationManager(CLLocationManager(), didUpdateLocations: locations)
        // The delegate hops to the main actor; let that land.
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// The `closest_approach_m` value on the most recent waypoint row.
    private func loggedClosestApproach(rowOffsetFromEnd: Int = 0) throws -> String {
        let logger = try XCTUnwrap(session.logger)
        let waypointRows = logger.events.filter { $0.type == .waypointTrigger }
        let event = try XCTUnwrap(waypointRows.dropLast(rowOffsetFromEnd).last)
        return event.closestApproachMetres.map { String(format: "%.1f", $0) } ?? ""
    }

    // MARK: - The minimum itself

    /// The recorded value must be the nearest point of the whole approach, not
    /// the distance at the moment the button was pressed.
    func testRecordsTheMinimumAcrossTheApproachNotTheFinalPosition() async throws {
        for metres in [120.0, 80.0, 41.0, 60.0, 150.0] {
            await deliver([fix(metresNorth: metres)])
        }
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 41, accuracy: 0.5,
                       "should report the nearest point, not the 150m it was pressed at")
    }

    /// iOS coalesces fixes — routinely while the screen is locked, which is
    /// the normal state on a walk. The nearest fix is often an intermediate
    /// one, so a batch must be searched rather than only its last element.
    func testFindsTheMinimumInsideABatchedUpdate() async throws {
        await deliver([
            fix(metresNorth: 90),
            fix(metresNorth: 33),   // nearest, and not the last element
            fix(metresNorth: 70)
        ])
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 33, accuracy: 0.5,
                       "a batched intermediate fix is still a real approach")
    }

    func testMinimumSurvivesAcrossSeparateUpdates() async throws {
        await deliver([fix(metresNorth: 75)])
        await deliver([fix(metresNorth: 25)])
        await deliver([fix(metresNorth: 95)])
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 25, accuracy: 0.5)
    }

    // MARK: - Trustworthiness

    /// A vague fix that happens to land near the waypoint would invent an
    /// approach that never happened — the one failure mode that would quietly
    /// produce a radius that is too small.
    func testImpreciseFixesCannotLowerTheMinimum() async throws {
        await deliver([fix(metresNorth: 60, accuracy: 5)])
        await deliver([fix(metresNorth: 2, accuracy: 400)])   // "on top of it", ±400m
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 60, accuracy: 0.5,
                       "a ±400m fix is not evidence of a 2m approach")
    }

    func testInvalidAccuracyIsIgnored() async throws {
        await deliver([fix(metresNorth: 45, accuracy: 5)])
        await deliver([fix(metresNorth: 1, accuracy: -1)])    // invalid fix
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 45, accuracy: 0.5)
    }

    /// Unknown must read as unknown. A zero here would be indistinguishable
    /// from standing on the waypoint and would drag a fitted radius to nothing.
    func testNoUsableFixesLeavesTheColumnBlank() async throws {
        await deliver([fix(metresNorth: 10, accuracy: 250)])
        session.playCurrentWaypoint()

        XCTAssertEqual(try loggedClosestApproach(), "",
                       "blank, not 0.0 — an absent measurement is not a close one")
    }

    // MARK: - Scoping to the right waypoint

    /// Each waypoint's figure must describe the approach to *that* waypoint.
    /// A value carried over would make every later waypoint look closer than
    /// it was.
    func testTheMinimumResetsForEachWaypoint() async throws {
        await deliver([fix(metresNorth: 12)])
        session.playCurrentWaypoint()                    // waypoint 1: 12m

        // Now much further from waypoint 1's position, approaching waypoint 2.
        await deliver([fix(metresNorth: 300)])
        session.playCurrentWaypoint()                    // waypoint 2

        let waypoint1Value = try Double(loggedClosestApproach(rowOffsetFromEnd: 1)) ?? .nan
        XCTAssertEqual(waypoint1Value, 12, accuracy: 0.5)

        let waypoint2Value = try XCTUnwrap(Double(loggedClosestApproach()))
        XCTAssertGreaterThan(waypoint2Value, 50,
                             "waypoint 2 must not inherit waypoint 1's 12m")
    }

    /// Distances are measured to the armed waypoint, so the second row's value
    /// is the distance to waypoint 2 — not to waypoint 1.
    func testDistanceIsMeasuredToTheArmedWaypoint() async throws {
        session.playCurrentWaypoint()                    // clear waypoint 1

        // Stand exactly on waypoint 2 and confirm it reads ~0.
        let waypoint2 = walk.waypoints[1]
        await deliver([CLLocation(
            coordinate: waypoint2.coordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        )])
        session.playCurrentWaypoint()

        let recorded = try Double(loggedClosestApproach()) ?? .nan
        XCTAssertEqual(recorded, 0, accuracy: 1.5,
                       "standing on waypoint 2 should read ~0m to waypoint 2")
    }

    // MARK: - Which rows carry it

    func testManualRowsCarryTheValue() async throws {
        await deliver([fix(metresNorth: 30)])
        session.playCurrentWaypoint()

        let logger = try XCTUnwrap(session.logger)
        let row = try XCTUnwrap(logger.events.last { $0.type == .waypointTrigger })
        XCTAssertEqual(row.triggerSource, .manual)
        XCTAssertNotNil(row.closestApproachMetres)
    }

    /// End to end through the CSV text, not just the in-memory event, so a
    /// formatting or column-order mistake cannot hide.
    func testValueReachesTheCSVInItsOwnColumn() async throws {
        await deliver([fix(metresNorth: 37.5)])
        session.playCurrentWaypoint()

        let logger = try XCTUnwrap(session.logger)
        let lines = logger.csvText.split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let columnIndex = try XCTUnwrap(header.firstIndex(of: "closest_approach_m"))

        let triggerRow = try XCTUnwrap(lines.first { $0.contains("waypoint_trigger") })
        let fields = triggerRow.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let value = try XCTUnwrap(Double(fields[columnIndex]))
        XCTAssertEqual(value, 37.5, accuracy: 0.5)
    }

    /// Reported from the simulator: the first waypoint gets a closest approach
    /// and every later one is blank. Cueing several waypoints in a row is
    /// faster than fixes arrive, so each newly armed waypoint has seen nothing
    /// by the time it is played.
    func testEveryWaypointGetsAValueWhenCuedFasterThanFixesArrive() async throws {
        await deliver([fix(metresNorth: 40)])

        for _ in 0..<4 { session.playCurrentWaypoint() }

        let logger = try XCTUnwrap(session.logger)
        let rows = logger.events.filter { $0.type == .waypointTrigger }
        XCTAssertEqual(rows.count, 4)
        let missing = rows.enumerated()
            .filter { $0.element.closestApproachMetres == nil }
            .map { "waypoint \($0.offset + 1)" }
        XCTAssertTrue(missing.isEmpty, "no closest approach recorded for: \(missing)")
    }
}
