import XCTest
@testable import WayWalkResearch

final class RouteDataTests: XCTestCase {

    // MARK: - JSON decoding

    func testWaypointDecodesAllFields() throws {
        let json = """
        {
            "id": "test1",
            "order": 1,
            "name": "1",
            "latitude": 51.524315,
            "longitude": -0.134529,
            "triggerRadius": 20,
            "navigationPrompt": "Go straight.",
            "contextualPrompt": "Go straight. You are on a wide street."
        }
        """.data(using: .utf8)!

        let wp = try JSONDecoder().decode(Waypoint.self, from: json)
        XCTAssertEqual(wp.id, "test1")
        XCTAssertEqual(wp.order, 1)
        XCTAssertEqual(wp.name, "1")
        XCTAssertEqual(wp.latitude, 51.524315)
        XCTAssertEqual(wp.longitude, -0.134529)
        XCTAssertEqual(wp.triggerRadius, 20)
        XCTAssertEqual(wp.navigationPrompt, "Go straight.")
        XCTAssertEqual(wp.contextualPrompt, "Go straight. You are on a wide street.")
    }

    func testWaypointDecodesWithoutContextualPrompt() throws {
        let json = """
        {
            "id": "test2",
            "order": 2,
            "name": "2",
            "latitude": 51.5,
            "longitude": -0.13,
            "triggerRadius": 20,
            "navigationPrompt": "Turn left."
        }
        """.data(using: .utf8)!

        let wp = try JSONDecoder().decode(Waypoint.self, from: json)
        // `contextualPrompt` is a non-optional `String`, so an absent key is
        // defaulted to "" rather than failing the decode — one waypoint
        // missing the field must not take the whole route file down with it.
        XCTAssertEqual(wp.contextualPrompt, "")
        // Absent is the same as empty: not on the contextual route. There is
        // deliberately no fallback to the navigation prompt.
        XCTAssertEqual(wp.script(for: .navigationPlusContext), "")
        XCTAssertFalse(wp.isOnRoute(for: .navigationPlusContext))
        XCTAssertTrue(wp.isOnRoute(for: .navigationOnly))
    }

    func testWaypointCoordinateProperty() throws {
        let json = """
        {
            "id": "coord",
            "order": 1,
            "name": "1",
            "latitude": 51.524315,
            "longitude": -0.134529,
            "triggerRadius": 20,
            "navigationPrompt": "Go."
        }
        """.data(using: .utf8)!

        let wp = try JSONDecoder().decode(Waypoint.self, from: json)
        XCTAssertEqual(wp.coordinate.latitude, 51.524315)
        XCTAssertEqual(wp.coordinate.longitude, -0.134529)
    }

    // MARK: - Walk loading from bundle

    func testWalkALoadsFromBundle() {
        let walk = RouteDataStore.shared.loadWalk(.walkA)
        XCTAssertNotNil(walk, "walkA.json should decode from the app bundle")
    }

    func testWalkBLoadsFromBundle() {
        let walk = RouteDataStore.shared.loadWalk(.walkB)
        XCTAssertNotNil(walk, "walkB.json should decode from the app bundle")
    }

    // MARK: - Waypoint count

    func testWalkAWaypointCount() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        XCTAssertEqual(walk.waypoints.count, 29)
    }

    func testWalkBWaypointCount() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        XCTAssertEqual(walk.waypoints.count, 31)
    }

    // MARK: - Ordering

    func testWalkAWaypointsAreInOrder() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        for i in 0..<walk.waypoints.count - 1 {
            XCTAssertLessThan(
                walk.waypoints[i].order, walk.waypoints[i + 1].order,
                "Waypoints should be sorted ascending by order"
            )
        }
    }

    func testWalkBWaypointsAreInOrder() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for i in 0..<walk.waypoints.count - 1 {
            XCTAssertLessThan(
                walk.waypoints[i].order, walk.waypoints[i + 1].order,
                "Waypoints should be sorted ascending by order"
            )
        }
    }

    // MARK: - Unique IDs

    func testWalkAHasUniqueIDs() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let ids = walk.waypoints.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Waypoint IDs must be unique")
    }

    func testWalkBHasUniqueIDs() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        let ids = walk.waypoints.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Waypoint IDs must be unique")
    }

    // MARK: - Prompts present

    /// Every waypoint must say *something* under at least one condition —
    /// a waypoint blank in both directions is a data error, not a design.
    func testEveryWaypointSaysSomethingInAtLeastOneCondition() throws {
        for wp in try allWaypoints() {
            let nav = wp.script(for: .navigationOnly).trimmingCharacters(in: .whitespacesAndNewlines)
            let context = wp.script(for: .navigationPlusContext)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(nav.isEmpty && context.isEmpty, "\(wp.id) is silent in both conditions")
        }
    }

    // MARK: - Condition-branched routes
    //
    // A waypoint with no script for a condition is not on that condition's
    // route: `WalkSession` skips it rather than firing it silently. These two
    // tests pin the exact off-route set per condition, and they are the guard
    // that makes dropping the old navigation-prompt fallback safe — without
    // them, a waypoint authored with a forgotten `contextualPrompt` would
    // quietly vanish from the contextual route and nobody would find out until
    // a participant walked past it.
    //
    // Both lists are in walk order. Update them only alongside a deliberate
    // route change.

    /// Waypoints that exist purely to deliver environmental context and carry
    /// no navigation instruction, plus `a11` — the contextual branch through
    /// Gordon Square. Skipped under Navigation Only.
    func testOffRouteUnderNavigationOnlyIsExactlyTheKnownSet() throws {
        let offRoute = try allWaypoints()
            .filter { !$0.isOnRoute(for: .navigationOnly) }
            .map(\.id)
        XCTAssertEqual(offRoute, ["a2", "a11", "a16", "b2", "b11", "b29", "b30"])
    }

    /// The navigation branches through Gordon Square — `a10` in Walk A, `b21`
    /// in Walk B — and nothing else. Under Navigation + Context the route
    /// crosses the square the other way, so these must not fire; before the
    /// fallback was removed they did, reading out the wrong turn in a
    /// synthesised voice because no `_context.mp3` was ever recorded for them.
    func testOffRouteUnderNavigationPlusContextIsExactlyTheKnownSet() throws {
        let offRoute = try allWaypoints()
            .filter { !$0.isOnRoute(for: .navigationPlusContext) }
            .map(\.id)
        XCTAssertEqual(offRoute, ["a10", "b21"])
    }

    /// The branch pairs must not overlap: a waypoint off both routes would be
    /// dead data, and the two conditions must each still reach the end.
    func testEachConditionHasAUsableRoute() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))

        XCTAssertEqual(walkA.routeLength(for: .navigationOnly), 26)
        XCTAssertEqual(walkA.routeLength(for: .navigationPlusContext), 28)
        XCTAssertEqual(walkB.routeLength(for: .navigationOnly), 27)
        XCTAssertEqual(walkB.routeLength(for: .navigationPlusContext), 30)
    }

    /// Every on-route waypoint must have its recording in the bundle. Missing
    /// files degrade to text-to-speech per prompt, which is survivable but is
    /// an audible condition confound in the middle of an otherwise recorded
    /// walk — and a route edit that outruns the recordings should fail here
    /// rather than in the field.
    func testEveryOnRouteWaypointHasItsRecording() throws {
        for wp in try allWaypoints() {
            for level in InformationLevel.allCases where wp.isOnRoute(for: level) {
                let key = wp.audioKey(for: level)
                XCTAssertNotNil(
                    Bundle.main.url(
                        forResource: key,
                        withExtension: "mp3",
                        subdirectory: "RecordedWaypointAudio"
                    ),
                    "\(key).mp3 is missing — \(wp.id) would fall back to TTS under \(level.rawValue)"
                )
            }
        }
    }

    private func allWaypoints() throws -> [Waypoint] {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        return walkA.waypoints + walkB.waypoints
    }

    // MARK: - Coordinates sanity (London bounding box)

    func testAllCoordinatesAreInLondon() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for wp in walkA.waypoints + walkB.waypoints {
            XCTAssertTrue((51.5...51.6).contains(wp.latitude),
                          "\(wp.id) latitude \(wp.latitude) outside London")
            XCTAssertTrue((-0.2...0.0).contains(wp.longitude),
                          "\(wp.id) longitude \(wp.longitude) outside London")
        }
    }

    // MARK: - Trigger radii

    func testAllTriggerRadiiArePositive() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for wp in walkA.waypoints + walkB.waypoints {
            XCTAssertGreaterThan(wp.triggerRadius, 0, "\(wp.id) radius must be positive")
        }
    }

    // MARK: - Waypoint name consistency

    /// Names are what the researcher sees in the banner and preview card, so
    /// they track the waypoint's position in the route rather than its id.
    func testWaypointNamesMatchTheirPositionInTheRoute() throws {
        for wp in try allWaypoints() {
            XCTAssertEqual(wp.name, "Waypoint \(wp.order)",
                           "\(wp.id) name should be \"Waypoint \(wp.order)\" but is \"\(wp.name)\"")
        }
    }

    /// 10 m is the calibration default — the distance at which a prompt
    /// actually fires, evaluated against the location fix stream rather than a
    /// geofence (see `WalkSession`) — and it is what all but six waypoints
    /// use. The exceptions are tuned to their own street geometry: a wider
    /// radius where the approach is open and GPS is the limiting factor, a
    /// tighter one where the next waypoint is close enough that 10 m would
    /// make one position satisfy both.
    ///
    /// Pinned per waypoint rather than as one shared value, because the radii
    /// are no longer uniform: a blanket "all equal" assertion would have to be
    /// deleted at the first deliberate tune, taking the guard with it. This
    /// shape still fails on a partial edit — some waypoints changed, some
    /// missed — and a deliberate tune is one line here.
    func testTriggerRadiiMatchTheirCalibratedValues() throws {
        let defaultRadius: Double = 10
        let tuned: [String: Double] = [
            "a22": 17, "a27": 5, "a28": 5,
            "b9": 17, "b16": 5, "b29": 5,
        ]

        for wp in try allWaypoints() {
            let expected = tuned[wp.id] ?? defaultRadius
            XCTAssertEqual(
                wp.triggerRadius, expected,
                "\(wp.id) fire radius is \(wp.triggerRadius)m, expected \(expected)m"
                    + (tuned[wp.id] == nil
                        ? " — tune it deliberately by adding it to `tuned` here"
                        : "")
            )
        }
    }

    // MARK: - Information level model

    func testInformationLevelHasTwoCases() {
        XCTAssertEqual(InformationLevel.allCases.count, 2)
    }

    func testInformationLevelDisplayNames() {
        XCTAssertEqual(InformationLevel.navigationOnly.rawValue, "Navigation Only")
        XCTAssertEqual(InformationLevel.navigationPlusContext.rawValue, "Navigation + Context")
    }

    // MARK: - Walk ID model

    func testWalkIDHasTwoCases() {
        XCTAssertEqual(WalkID.allCases.count, 2)
    }

    func testWalkIDFileNames() {
        XCTAssertEqual(WalkID.walkA.dataFileName, "walkA")
        XCTAssertEqual(WalkID.walkB.dataFileName, "walkB")
    }

}
