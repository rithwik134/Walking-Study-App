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

    func testContextFallsBackToNavigationWhenNoContextualScriptExists() {
        for contextual in [nil, ""] as [String?] {
            let waypoint = Waypoint(
                id: "a1", order: 1, name: "1",
                latitude: 51.5, longitude: -0.13, triggerRadius: 5,
                navigationPrompt: "Head south.",
                contextualPrompt: contextual
            )
            XCTAssertEqual(waypoint.script(for: .navigationPlusContext), "Head south.")
        }
    }

    // Per-condition script coverage across the shipped routes lives in
    // RouteDataTests, which distinguishes deliberately context-only waypoints
    // from genuinely missing prompts.

    // MARK: - Preview card prefix splitting

    func testSharedPrefixIsSplitOffSoAddedContextIsVisible() {
        let split = WaypointPreviewCard.splitSharedPrefix(
            navigation: "Head south on Gower Street.",
            contextual: "Head south on Gower Street. You are on a moderately busy street."
        )
        XCTAssertEqual(split?.shared, "Head south on Gower Street.")
        XCTAssertEqual(split?.added, "You are on a moderately busy street.")
    }

    /// Several navigation prompts in the route data have a trailing space
    /// that the contextual prompt does not repeat.
    func testTrailingWhitespaceInTheNavigationPromptDoesNotBreakTheSplit() {
        let split = WaypointPreviewCard.splitSharedPrefix(
            navigation: "Cross the road and turn left onto Torrington Place. ",
            contextual: "Cross the road and turn left onto Torrington Place. This crossing is signalled."
        )
        XCTAssertEqual(split?.shared, "Cross the road and turn left onto Torrington Place.")
        XCTAssertEqual(split?.added, "This crossing is signalled.")
    }

    /// About a third of the shipped scripts thread the extra detail into the
    /// middle of the instruction rather than appending it. An exact-prefix
    /// test finds nothing to dim on precisely these, which is why the split
    /// compares word by word.
    func testDetailInterleavedIntoTheInstructionStillSplits() {
        let byngPlace = WaypointPreviewCard.splitSharedPrefix(
            navigation: "Continue straight.",
            contextual: "Continue straight through Byng Place. This is a shared space."
        )
        XCTAssertEqual(byngPlace?.shared, "Continue straight")
        XCTAssertEqual(byngPlace?.added, "through Byng Place. This is a shared space.")

        let zebra = WaypointPreviewCard.splitSharedPrefix(
            navigation: "Exit the park and cross the road to enter Gordon Square.",
            contextual: "Exit the park and cross the road to enter Gordon Square using the zebra crossing. This crossing is intersected by cycleways."
        )
        XCTAssertEqual(zebra?.shared, "Exit the park and cross the road to enter Gordon Square")
        XCTAssertEqual(zebra?.added, "using the zebra crossing. This crossing is intersected by cycleways.")
    }

    func testNoSplitWhenTheContextualScriptIsWordedDifferently() {
        // Genuinely different wording from the first word — a15 in walkA is
        // written this way ("Exit Euston Station forecourt…" against
        // "Continue down the steps…").
        XCTAssertNil(
            WaypointPreviewCard.splitSharedPrefix(
                navigation: "Exit Euston Station forecourt, then turn right.",
                contextual: "Continue down the steps to Eversholt Street, then turn right."
            )
        )
        // Shares only one word, which is not enough to be a meaningful
        // shared opening.
        XCTAssertNil(
            WaypointPreviewCard.splitSharedPrefix(
                navigation: "Head south on Gower Street.",
                contextual: "Head down Gower Street, which is busy."
            )
        )
        XCTAssertNil(
            WaypointPreviewCard.splitSharedPrefix(navigation: "", contextual: "Anything")
        )
    }

    func testIdenticalScriptsHaveNothingToAdd() {
        XCTAssertNil(
            WaypointPreviewCard.splitSharedPrefix(
                navigation: "Continue straight.",
                contextual: "Continue straight."
            )
        )
    }

    /// The preview card's dimmed-opening rendering is only worth anything if
    /// it fires on a decent share of the real scripts. A floor rather than an
    /// exact list, because the route wording is edited often and pinning IDs
    /// would fail on every rewrite without telling anyone anything useful.
    func testAMeaningfulShareOfShippedContextualPromptsSplit() throws {
        var comparable = 0
        var unsplit: [String] = []

        for waypoint in try allWaypointsWithBothScripts() {
            comparable += 1
            if WaypointPreviewCard.splitSharedPrefix(
                navigation: waypoint.navigationPrompt,
                contextual: waypoint.contextualPrompt ?? ""
            ) == nil {
                unsplit.append(waypoint.id)
            }
        }

        XCTAssertGreaterThan(comparable, 20)
        let ratio = Double(comparable - unsplit.count) / Double(comparable)
        XCTAssertGreaterThan(
            ratio, 0.4,
            "only \(comparable - unsplit.count)/\(comparable) contextual prompts share an "
                + "opening with their navigation prompt; these do not: \(unsplit)"
        )
    }

    /// Where a split does happen it must be lossless — the dimmed opening
    /// plus the highlighted remainder has to reconstruct the script the
    /// participant actually hears, or the card is showing something the app
    /// will not say.
    func testSplittingIsLosslessAcrossTheShippedScripts() throws {
        for waypoint in try allWaypointsWithBothScripts() {
            let contextual = (waypoint.contextualPrompt ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (shared, added) = WaypointPreviewCard.splitSharedPrefix(
                navigation: waypoint.navigationPrompt,
                contextual: contextual
            ) else { continue }

            let recombined = "\(shared) \(added)"
            let normalise: (String) -> String = {
                $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            XCTAssertEqual(
                normalise(recombined), normalise(contextual),
                "\(waypoint.id) split does not reconstruct its contextual script"
            )
        }
    }

    /// Waypoints that carry only context have no navigation instruction to
    /// share an opening with, so they always render whole.
    func testContextOnlyWaypointsNeverSplit() throws {
        for id in WalkID.allCases {
            let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(id))
            for waypoint in walk.waypoints
            where waypoint.navigationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertNil(
                    WaypointPreviewCard.splitSharedPrefix(
                        navigation: waypoint.navigationPrompt,
                        contextual: waypoint.contextualPrompt ?? ""
                    ),
                    "\(waypoint.id) has no navigation prompt, so nothing can be shared"
                )
            }
        }
    }

    /// Waypoints that have a real script in both conditions — the only ones
    /// where comparing the two is meaningful.
    private func allWaypointsWithBothScripts() throws -> [Waypoint] {
        var result: [Waypoint] = []
        for id in WalkID.allCases {
            let walk = try XCTUnwrap(RouteDataStore.shared.loadWalk(id))
            result += walk.waypoints.filter {
                !$0.navigationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !($0.contextualPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return result
    }
}
