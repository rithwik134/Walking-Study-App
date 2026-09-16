import XCTest
import CoreLocation
@testable import WayWalkResearch

/// Covers the precomputed walking path and the prompt-preview logic that the
/// researcher screens rely on.
final class RoutePathTests: XCTestCase {

    // MARK: - RoutePath

    func testRoutePathRoundTripsThroughJSON() throws {
        let locations = [
            CLLocationCoordinate2D(latitude: 51.524315, longitude: -0.134529),
            CLLocationCoordinate2D(latitude: 51.522553, longitude: -0.132625)
        ]
        let path = RoutePath(
            walkID: .walkA,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            locations: locations
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(path)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RoutePath.self, from: data)

        XCTAssertEqual(decoded, path)
        XCTAssertEqual(decoded.walkID, .walkA)
        XCTAssertEqual(decoded.locations.count, 2)
        XCTAssertEqual(decoded.locations[0].latitude, 51.524315, accuracy: 1e-9)
        XCTAssertEqual(decoded.locations[1].longitude, -0.132625, accuracy: 1e-9)
    }

    func testMalformedCoordinatePairsAreDropped() throws {
        let json = """
        {
          "walkID": "walkA",
          "generatedAt": "2026-08-06T10:00:00Z",
          "coordinates": [[51.5, -0.13], [51.6], [51.7, -0.14, 99]]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let path = try decoder.decode(RoutePath.self, from: Data(json.utf8))

        XCTAssertEqual(path.coordinates.count, 3)
        XCTAssertEqual(path.locations.count, 1, "only well-formed [lat, lng] pairs become coordinates")
    }

    // MARK: - RoutePathStore

    /// Both routed paths are generated and committed, so they must be in the
    /// bundle and decode. If one is ever dropped from Copy Bundle Resources
    /// the maps silently regress to straight lines, which is exactly the
    /// thing this feature exists to fix.
    func testBothRoutedPathsAreCommittedAndDecode() throws {
        for id in WalkID.allCases {
            XCTAssertTrue(
                RoutePathStore.shared.hasRoutedPath(for: id),
                "\(RoutePathStore.fileName(for: id)).json is missing from the app bundle"
            )
            let path = try XCTUnwrap(RoutePathStore.shared.path(for: id))
            XCTAssertEqual(path.walkID, id)
            XCTAssertGreaterThan(path.locations.count, 17)
        }
    }

    /// The routed path must follow the pavement between the same two ends as
    /// the waypoint list — denser than the waypoints, but starting and
    /// finishing in the same places.
    func testRoutedPolylineIsDenserThanTheWaypointsAndSharesItsEnds() throws {
        for id in WalkID.allCases {
            let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(id))
            let polyline = RoutePathStore.shared.polyline(for: walk)

            XCTAssertGreaterThan(polyline.count, walk.waypoints.count)
            assertClose(polyline.first!, walk.waypoints.first!.coordinate, within: 30)
            assertClose(polyline.last!, walk.waypoints.last!.coordinate, within: 30)
        }
    }

    /// A walk with no committed path degrades to the straight-line join of
    /// its waypoints rather than drawing nothing.
    func testPolylineFallsBackToWaypointsWhenNoPathIsCommitted() throws {
        let waypoints = try XCTUnwrap(RouteDataStore.shared.loadWalk(.walkA)).waypoints
        let polyline = RoutePathStore.polyline(
            for: Walk(id: .walkA, waypoints: waypoints),
            routedPath: nil
        )

        XCTAssertEqual(polyline.count, waypoints.count)
        assertClose(polyline.first!, waypoints.first!.coordinate, within: 0.5)
        assertClose(polyline.last!, waypoints.last!.coordinate, within: 0.5)
    }

    func testPathFileNameMatchesTheExpectedBundleResource() {
        XCTAssertEqual(RoutePathStore.fileName(for: .walkA), "walkA_path")
        XCTAssertEqual(RoutePathStore.fileName(for: .walkB), "walkB_path")
    }

    private func assertClose(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D,
        within metres: CLLocationDistance,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let distance = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
        XCTAssertLessThanOrEqual(distance, metres, "points are \(distance)m apart", file: file, line: line)
    }

    // MARK: - Waypoint script selection

    func testScriptForConditionPicksExactlyOneStript() {
        let waypoint = Waypoint(
            id: "a1", order: 1, name: "1",
            latitude: 51.5, longitude: -0.13, triggerRadius: 5,
            navigationPrompt: "Head south.",
            contextualPrompt: "Head south. The pavement is wide."
        )

        XCTAssertEqual(waypoint.script(for: .navigationOnly), "Head south.")
        XCTAssertEqual(waypoint.script(for: .navigationPlusContext), "Head south. The pavement is wide.")
        XCTAssertEqual(waypoint.audioKey(for: .navigationOnly), "a1_nav")
        XCTAssertEqual(waypoint.audioKey(for: .navigationPlusContext), "a1_context")
    }

    /// No cross-condition fallback, in either direction. A missing script means
    /// the waypoint is off that condition's route and is skipped, not that it
    /// borrows the other condition's line — borrowing is what made the Gordon
    /// Square navigation branch speak its turn during a contextual walk.
    func testAMissingScriptMeansOffRouteNotFallback() {
        // `contextualPrompt` is non-optional, so "absent" reaches the model as
        // an empty or whitespace-only string — both must read as off-route.
        for contextual in ["", "   "] {
            let waypoint = Waypoint(
                id: "a10", order: 10, name: "10",
                latitude: 51.5, longitude: -0.13, triggerRadius: 5,
                navigationPrompt: "Head south.",
                contextualPrompt: contextual
            )
            XCTAssertFalse(waypoint.isOnRoute(for: .navigationPlusContext))
            XCTAssertNotEqual(waypoint.script(for: .navigationPlusContext), "Head south.")
            XCTAssertTrue(waypoint.isOnRoute(for: .navigationOnly))
        }

        let contextOnly = Waypoint(
            id: "a11", order: 11, name: "11",
            latitude: 51.5, longitude: -0.13, triggerRadius: 5,
            navigationPrompt: "",
            contextualPrompt: "Turn right to exit the square."
        )
        XCTAssertFalse(contextOnly.isOnRoute(for: .navigationOnly))
        XCTAssertTrue(contextOnly.isOnRoute(for: .navigationPlusContext))
    }

    // Per-condition script coverage across the shipped routes lives in
    // RouteDataTests, which distinguishes deliberately context-only waypoints
    // from genuinely missing prompts.
}
