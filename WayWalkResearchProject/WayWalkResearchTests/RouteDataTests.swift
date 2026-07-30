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

    func testWalkAHas17Waypoints() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        XCTAssertEqual(walk.waypoints.count, 17)
    }

    func testWalkBHas17Waypoints() throws {
        let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        XCTAssertEqual(walk.waypoints.count, 17)
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

    func testEveryWaypointHasNavigationPrompt() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for wp in walkA.waypoints + walkB.waypoints {
            XCTAssertFalse(wp.navigationPrompt.isEmpty, "\(wp.id) missing navigation prompt")
        }
    }

    func testEveryWaypointHasContextualPrompt() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for wp in walkA.waypoints + walkB.waypoints {
            XCTAssertNotNil(wp.contextualPrompt, "\(wp.id) missing contextual prompt")
            XCTAssertFalse(wp.contextualPrompt?.isEmpty ?? true, "\(wp.id) contextual prompt is empty")
        }
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

    func testWaypointNamesAreNumeric() throws {
        let walkA = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA))
        let walkB = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkB))
        for walk in [walkA, walkB] {
            for (index, wp) in walk.waypoints.enumerated() {
                XCTAssertEqual(wp.name, "\(index + 1)",
                               "\(wp.id) name should be \"\(index + 1)\" but is \"\(wp.name)\"")
            }
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
