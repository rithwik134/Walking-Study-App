import Foundation
import CoreLocation

/// A precomputed walking path for one route: the line actually drawn on the
/// map, following pavements and crossings rather than cutting straight
/// through buildings.
///
/// This is generated once by a researcher (see `RoutePathBuilder`) and
/// committed to the app bundle as `walkA_path.json` / `walkB_path.json`,
/// rather than fetched at walk time. Three reasons, in order of importance:
///
/// 1. **Every participant sees the same line.** Apple's map data changes; a
///    path fetched live could differ between the first and last participant
///    in a study.
/// 2. **It works with no signal**, which a route fetched at walk start does
///    not.
/// 3. **No startup latency and no throttling.** 17 waypoints means 16
///    directions requests, which is enough to be rate-limited.
///
/// The path is decoration for the researcher's benefit. Navigation ground
/// truth is, and remains, the pre-written prompts in the route JSON.
struct RoutePath: Codable, Equatable {
    let walkID: WalkID
    let generatedAt: Date
    /// `[[latitude, longitude], …]` — a flat array keeps the committed file
    /// readable and diffable.
    let coordinates: [[Double]]

    var locations: [CLLocationCoordinate2D] {
        coordinates.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    init(walkID: WalkID, generatedAt: Date = Date(), locations: [CLLocationCoordinate2D]) {
        self.walkID = walkID
        self.generatedAt = generatedAt
        self.coordinates = locations.map { [$0.latitude, $0.longitude] }
    }
}
