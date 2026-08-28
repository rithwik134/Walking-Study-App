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
        XCTAssertNil(wp.contextualPrompt)
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
        XCTAssertEqual(walk.waypoints.count, 28)
    }

    func testWalkBWaypointCount() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        XCTAssertEqual(walk.waypoints.count, 27)
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

    /// The contextual condition must never be silent: where a waypoint has no
    /// contextual script, `script(for:)` falls back to the navigation prompt.
    func testContextualConditionIsNeverSilent() throws {
        for wp in try allWaypoints() {
            let script = wp.script(for: .navigationPlusContext)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(script.isEmpty, "\(wp.id) has nothing to say in Navigation + Context")
        }
    }

    /// Some waypoints exist purely to deliver environmental context and carry
    /// no navigation instruction, so they are deliberately silent in the
    /// Navigation Only condition. Pinned so that a data edit which blanks a
    /// prompt by accident shows up as a failure rather than as silence in the
    /// field.
    func testOnlyTheKnownContextOnlyWaypointsAreSilentInNavigationOnly() throws {
        var silent: [String] = []
        for wp in try allWaypoints() {
            if wp.script(for: .navigationOnly)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                silent.append(wp.id)
            }
        }
        XCTAssertEqual(silent, ["a2", "a11", "a16", "b2", "b10", "b26"])
    }

    /// Where a contextual script is absent the app must fall back rather than
    /// go quiet — these are the waypoints relying on that fallback today.
    func testWaypointsWithoutContextualScriptFallBackToNavigation() throws {
        for wp in try allWaypoints() where (wp.contextualPrompt ?? "").isEmpty {
            XCTAssertEqual(wp.script(for: .navigationPlusContext), wp.navigationPrompt)
            XCTAssertFalse(wp.navigationPrompt.isEmpty, "\(wp.id) has neither script")
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

    /// Trigger radii must stay well clear of the GPS noise floor. iOS region
    /// monitoring is not precise at small radii, and the previous route data
    /// used 5m, which is below what CoreLocation can resolve.
    func testAllTriggerRadiiAreAboveTheGPSNoiseFloor() throws {
        for wp in try allWaypoints() {
            XCTAssertGreaterThanOrEqual(
                wp.triggerRadius, 8,
                "\(wp.id) radius \(wp.triggerRadius)m is too small to trigger reliably"
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
