import XCTest
import CoreLocation
@testable import WayWalkResearch

/// Walks a synthetic participant along the real walkA geometry at walking
/// pace, with realistic GPS noise, and checks what the trigger and the CSV
/// actually do end to end.
///
/// This is the closest thing to a device walk that runs offline. It exercises
/// the real `WalkSession`, the real route data and the real `SessionLogger`;
/// only the fixes are synthetic. Because the trigger no longer depends on
/// CoreLocation's region behaviour, a synthetic fix stream is a fair test of
/// it — which was not true of the previous design.
///
/// It cannot tell you how iOS clamps geofences on real hardware. That still
/// needs a phone.
@MainActor
final class SimulatedWalkTests: XCTestCase {

    // MARK: - Deterministic noise

    /// Small LCG so a "noisy" walk is byte-identical on every run. A flaky
    /// trigger test would be worse than no trigger test.
    private struct SeededRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Roughly Gaussian, via the sum of three uniforms.
        mutating func noise(sigma: Double) -> Double {
            let u = next() + next() + next() - 1.5
            return u * sigma * 1.4
        }
    }

    // MARK: - Local metre frame

    /// Route geometry is easier to reason about in metres. All legs here are
    /// well under a kilometre, so a flat local frame is exact enough.
    private struct Frame {
        let originLat: Double
        let originLon: Double
        var metresPerDegreeLat: Double { 111_320 }
        var metresPerDegreeLon: Double { 111_320 * cos(originLat * .pi / 180) }

        func toMetres(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - originLon) * metresPerDegreeLon,
             (c.latitude - originLat) * metresPerDegreeLat)
        }
        func toCoordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: originLat + y / metresPerDegreeLat,
                                   longitude: originLon + x / metresPerDegreeLon)
        }
    }

    // MARK: - The walk

    /// Fixes along the first three waypoints *of the Navigation Only route*
    /// through walkA, at 1.4 m/s, one per second, with `sigma` metres of
    /// positional noise.
    private func simulatedFixes(
        walk: Walk,
        level: InformationLevel = .navigationOnly,
        waypointCount: Int = 3,
        sigma: Double,
        reportedAccuracy: CLLocationAccuracy,
        lateralOffset: Double = 0,
        seed: UInt64 = 42
    ) -> [CLLocation] {
        var rng = SeededRNG(seed: seed)
        let frame = Frame(originLat: walk.waypoints[0].latitude,
                          originLon: walk.waypoints[0].longitude)
        // The waypoints this condition actually arms, not the raw array. `a2`
        // carries no navigation script, so under Navigation Only it is skipped
        // and can never fire — routing the simulated walk over it would leave
        // this harness expecting a prompt that is not supposed to exist. The
        // two conditions genuinely diverge through Gordon Square, so this is
        // also what makes the contextual walk follow its own path.
        let route = walk.waypoints.filter { $0.isOnRoute(for: level) }
        let points = route.prefix(waypointCount).map { frame.toMetres($0.coordinate) }

        // Approach from 30m before waypoint 1, on the line back from waypoint 2,
        // and carry on 30m past the last waypoint.
        var legs: [((Double, Double), (Double, Double))] = []
        let inBearing = unit(from: points[1], to: points[0])
        let start = (points[0].x + inBearing.0 * 30, points[0].y + inBearing.1 * 30)
        legs.append((start, (points[0].x, points[0].y)))
        for i in 0..<(points.count - 1) {
            legs.append(((points[i].x, points[i].y), (points[i + 1].x, points[i + 1].y)))
        }
        let outBearing = unit(from: points[points.count - 2], to: points[points.count - 1])
        // 80m of run-out, not 30m: backstop B needs the participant to travel
        // `backstopRecedeDistance` past their closest approach before it can
        // infer they have passed, and a walk that stops short simply leaves the
        // last waypoint armed.
        let end = (points.last!.x + outBearing.0 * 80, points.last!.y + outBearing.1 * 80)
        legs.append(((points.last!.x, points.last!.y), end))

        var fixes: [CLLocation] = []
        let speed = 1.4          // m/s, unhurried walking
        let startTime = Date(timeIntervalSince1970: 1_700_000_000)

        for (a, b) in legs {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }
            let steps = max(1, Int(length / speed))
            // Perpendicular, for walking along a pavement rather than over the pin.
            let perp = (-dy / length, dx / length)
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let x = a.0 + dx * t + perp.0 * lateralOffset + rng.noise(sigma: sigma)
                let y = a.1 + dy * t + perp.1 * lateralOffset + rng.noise(sigma: sigma)
                fixes.append(CLLocation(
                    coordinate: frame.toCoordinate(x: x, y: y),
                    altitude: 0,
                    horizontalAccuracy: reportedAccuracy,
                    verticalAccuracy: 5,
                    timestamp: startTime.addingTimeInterval(Double(fixes.count))
                ))
            }
        }
        return fixes
    }

    private func unit(from a: (x: Double, y: Double), to b: (x: Double, y: Double)) -> (Double, Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = (dx * dx + dy * dy).squareRoot()
        return d == 0 ? (0, 0) : (dx / d, dy / d)
    }

    // MARK: - Reporting

    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    private func report(_ title: String, session: WalkSession, walk: Walk, fixCount: Int) {
        let rows = session.logger?.events.filter { $0.type == .waypointTrigger } ?? []
        print("\nSIMWALK === \(title) — \(fixCount) fixes ===")
        print("SIMWALK fired: \(rows.count) waypoint(s)")
        print("SIMWALK " + pad("wp", 6) + pad("source", 11)
              + pad("closest", 10) + pad("at-fire", 10) + "note")
        for row in rows {
            let closest = row.closestApproachMetres.map { String(format: "%.1f m", $0) } ?? "—"
            let atFire = row.triggerDistanceMetres.map { String(format: "%.1f m", $0) } ?? "—"
            print("SIMWALK " + pad(row.waypointID ?? "?", 6)
                  + pad(row.triggerSource?.rawValue ?? "?", 11)
                  + pad(closest, 10) + pad(atFire, 10) + (row.note ?? ""))
        }
        // Elapsed between consecutive fires, in *simulated* time — the
        // chain-fire tell. Must come from the fix timestamps, not the row's
        // own `timestamp`: this harness feeds a 4-minute walk through in a
        // fraction of a second, so wall clock says everything happened at
        // once. (Which is a neat demonstration of why `fix_age_s` exists.)
        for (a, b) in zip(rows, rows.dropFirst()) {
            guard let ta = a.fixTimestamp, let tb = b.fixTimestamp else { continue }
            let gap = tb.timeIntervalSince(ta)
            let flag = gap < 5 ? "   <-- SUSPICIOUS, possible chain-fire" : ""
            print("SIMWALK   gap \(a.waypointID ?? "?") -> \(b.waypointID ?? "?"): "
                  + String(format: "%.0fs walked", gap) + flag)
        }
    }

    private func runWalk(
        sigma: Double,
        reportedAccuracy: CLLocationAccuracy,
        lateralOffset: Double = 0,
        title: String
    ) async throws -> (session: WalkSession, walk: Walk, fired: [SessionEvent]) {
        let player = FakePromptPlayer()
        let session = WalkSession(audioPlayer: player, locationManager: SilentLocationManager())
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly,
                      participantID: "SIM", mode: .test)

        let fixes = simulatedFixes(walk: walk, sigma: sigma,
                                   reportedAccuracy: reportedAccuracy,
                                   lateralOffset: lateralOffset)
        for fix in fixes {
            session.locationManager(CLLocationManager(), didUpdateLocations: [fix])
            try? await Task.sleep(for: .milliseconds(2))
            if session.triggeredWaypointIDs.count >= 3 { break }
        }

        report(title, session: session, walk: walk, fixCount: fixes.count)
        let fired = session.logger?.events.filter { $0.type == .waypointTrigger } ?? []
        return (session, walk, fired)
    }

    // MARK: - Tests

    /// Good conditions: ±5 m noise, walking over the waypoints.
    func testCleanWalkFiresAllThreeCloseToTheWaypoints() async throws {
        let (_, _, fired) = try await runWalk(
            sigma: 5, reportedAccuracy: 8, title: "clean walk (sigma 5m, reported +/-8m)")

        XCTAssertEqual(fired.count, 3, "all three waypoints should fire")
        for row in fired {
            XCTAssertEqual(row.triggerSource, .automatic)
            XCTAssertNil(row.note, "\(row.waypointID ?? "?") should not have needed a backstop")
            let closest = try XCTUnwrap(row.closestApproachMetres)
            XCTAssertLessThan(closest, 10, "\(row.waypointID ?? "?") never got within 10m")
            // The number that decides whether the instruction was useful: a
            // clean fire must happen *at* the waypoint, not merely after
            // having once been near it.
            let atFire = try XCTUnwrap(row.triggerDistanceMetres)
            XCTAssertLessThanOrEqual(atFire, 10,
                "\(row.waypointID ?? "?") played \(atFire)m from the waypoint")
        }
    }

    /// A typical urban street canyon: ±12 m noise, and the participant walking
    /// 5 m to one side of the pins rather than over them.
    func testNoisyOffsetWalkStillProgresses() async throws {
        let (_, _, fired) = try await runWalk(
            sigma: 12, reportedAccuracy: 20, lateralOffset: 5,
            title: "noisy offset walk (sigma 12m, +/-20m, 5m off-line)")

        XCTAssertEqual(fired.count, 3, "the walk must not stall, even if backstops carry it")
    }

    /// Fixes too imprecise to fire on: everything should fall through to a
    /// backstop, and the walk must still progress rather than stalling.
    func testPoorAccuracyFallsThroughToBackstopsWithoutStalling() async throws {
        let (_, _, fired) = try await runWalk(
            sigma: 12, reportedAccuracy: 40,
            title: "poor accuracy (reported +/-40m, above the 25m limit)")

        XCTAssertGreaterThanOrEqual(fired.count, 3, "backstops must keep the walk moving")
        for row in fired {
            XCTAssertNotNil(row.note, "with no fix accurate enough to fire on, every row should be a backstop")
            XCTAssertEqual(row.note, "backstop: receded")
        }
    }

    /// Locked-screen batching: the same walk, delivered in bursts of 15 fixes.
    func testBatchedDeliveryStillFiresEachWaypointOnce() async throws {
        let player = FakePromptPlayer()
        let session = WalkSession(audioPlayer: player, locationManager: SilentLocationManager())
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        session.start(walk: walk, informationLevel: .navigationOnly,
                      participantID: "SIMBATCH", mode: .test)

        let fixes = simulatedFixes(walk: walk, sigma: 5, reportedAccuracy: 8)
        for batch in stride(from: 0, to: fixes.count, by: 15).map({
            Array(fixes[$0..<min($0 + 15, fixes.count)])
        }) {
            session.locationManager(CLLocationManager(), didUpdateLocations: batch)
            try? await Task.sleep(for: .milliseconds(20))
        }

        report("batched delivery (15 fixes per burst)", session: session, walk: walk, fixCount: fixes.count)

        let fired = session.logger?.events.filter { $0.type == .waypointTrigger } ?? []
        XCTAssertGreaterThanOrEqual(fired.count, 3)
        XCTAssertEqual(Set(fired.compactMap(\.waypointID)).count, fired.count,
                       "no waypoint may fire twice")

        // The CSV as a researcher would receive it.
        print("\n--- CSV (first 5 rows) ---")
        for line in (session.logger?.csvText ?? "").split(separator: "\n").prefix(5) {
            print(line)
        }
    }

    // MARK: - Whole routes, both conditions

    /// **The Gordon Square regression.** Walk both routes end to end, in both
    /// conditions, and require every waypoint on that condition's route to
    /// fire exactly once.
    ///
    /// Before waypoints were skipped by condition, Walk A under Navigation Only
    /// stalled permanently at `a11`: the contextual branch is ~33m away across
    /// the square, outside its 10m radius, and the recede backstop could not
    /// rescue it because the seeded closest approach already exceeded
    /// `backstopApproachDistance`. Everything from `a11` onward was lost. The
    /// symmetric failure under Navigation + Context was `a10` firing and
    /// reading out the wrong turn.
    func testEveryConditionWalksItsWholeRouteWithoutStalling() async throws {
        for walkID in WalkID.allCases {
            for level in InformationLevel.allCases {
                let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(walkID))
                let expected = walk.waypoints.filter { $0.isOnRoute(for: level) }.map(\.id)

                let session = WalkSession(audioPlayer: FakePromptPlayer(),
                                          locationManager: SilentLocationManager())
                session.start(walk: walk, informationLevel: level,
                              participantID: "SIMFULL", mode: .test)

                let fixes = simulatedFixes(walk: walk, level: level,
                                           waypointCount: expected.count,
                                           sigma: 5, reportedAccuracy: 8)
                for fix in fixes {
                    session.locationManager(CLLocationManager(), didUpdateLocations: [fix])
                    try? await Task.sleep(for: .milliseconds(1))
                    if session.routeIsComplete { break }
                }

                let fired = (session.logger?.events ?? [])
                    .filter { $0.type == .waypointTrigger }
                    .compactMap(\.waypointID)

                XCTAssertEqual(fired, expected,
                    "\(walkID.rawValue) / \(level.rawValue): every on-route waypoint should fire once, in order")
                XCTAssertTrue(session.routeIsComplete,
                    "\(walkID.rawValue) / \(level.rawValue): the walk stalled")

                // And the off-route branch must be absent from the CSV entirely,
                // not merely present with a blank script.
                for wp in walk.waypoints where !wp.isOnRoute(for: level) {
                    XCTAssertFalse(fired.contains(wp.id),
                        "\(wp.id) is off the \(level.rawValue) route and must not be logged")
                }
            }
        }
    }
}
